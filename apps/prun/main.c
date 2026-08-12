/*
 * prun -- run a batch of shell commands on the device concurrently.
 *
 * Copyright (c) 2025 Mateusz Stadnik
 *
 * The smoke suite drives the device over one serial console, one command at a
 * time, so a test costs a full console round trip whatever the device is doing.
 * This runs a whole batch from a single round trip: it starts up to -j children
 * at once and prints one result line per job when they finish.
 *
 * `cmd &` in the shell does not work here -- toybox takes the fork() path and
 * this kernel has only vfork(). vfork() is enough: yasos unblocks the parent
 * when the child execs rather than when it exits, so after each spawn the
 * parent is runnable while the child keeps going.
 *
 * Two constraints that are not obvious:
 *
 *  - Never pass `environ` to exec. The kernel builds argv and environ on the
 *    kernel heap and uaccess refuses those addresses to userspace, so
 *    execv()/execvp() fail with EFAULT. Every spawn here uses execve with a
 *    local, empty environment.
 *
 *  - Jobs are exec'd directly, not through `sh -c`: spawning /bin/sh from a
 *    vforked child HardFaults this kernel, so prun does its own redirection --
 *    the child opens its log, dup2()s it over stdout and stderr, and execs.
 *    Safe despite vfork sharing memory, because descriptors are not shared.
 *
 * Usage:
 *   prun [-j N] [-o LOGDIR] <batchfile>
 *
 * The batch file holds one command per line, as a plain argv (whitespace
 * separated, no shell syntax -- no pipes, redirection or variables); blank
 * lines and lines starting with '#' are ignored. Each line is numbered from 0
 * in file order, its output goes to LOGDIR/<index>.log, and each finished job
 * prints:
 *
 *   PRUN <index> <exit-status>
 *
 * exit-status is the child's exit code, or 128+signal if it was killed, or -1
 * if it could not be started at all. Results are printed in *completion* order,
 * which is why the index is on the line: with -j > 1 the order is not the file
 * order, and the caller matches on the index rather than position.
 *
 * The caller is expected to have each command redirect its own output to its
 * own file, and to read those back afterwards -- interleaving N jobs' stdout on
 * one console would be unreadable, and unattributable.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAX_JOBS 512
#define MAX_LINE 1024
#define MAX_ARGS 64
#define DEFAULT_PARALLEL 4
#define ARENA_BYTES (64 * 1024)

/*
 * Commands live in this static arena rather than malloc'd blocks, and that is a
 * correctness requirement: a user process's malloc returns kernel-heap memory
 * here, which uaccess refuses to read for a syscall, so execve() with a
 * malloc'd argv entry fails with EFAULT. Static storage is part of the process
 * image, which uaccess does accept.
 */
static char arena[ARENA_BYTES];
static size_t arena_used;

static char *commands[MAX_JOBS];
static int command_count;

static char *arena_dup(const char *text, size_t len)
{
    char *out;

    if (arena_used + len + 1 > sizeof(arena)) {
        return NULL;
    }
    out = &arena[arena_used];
    memcpy(out, text, len);
    out[len] = 0;
    arena_used += len + 1;
    return out;
}

/* Slots for the children currently running: pid and the job it belongs to. */
static pid_t running_pid[MAX_JOBS];
static int running_job[MAX_JOBS];
static int running_count;

static char logdir[MAX_LINE] = "/tmp";
static char logpath[MAX_LINE];

/* argv vectors for the job being spawned, rebuilt per spawn. */
static char *job_argv[MAX_ARGS];

/* Split `line` in place into job_argv. Returns the count, or -1 if too many. */
static int split_args(char *line)
{
    int count = 0;
    char *p = line;

    while (*p != 0) {
        while (*p == ' ' || *p == '\t') {
            p++;
        }
        if (*p == 0) {
            break;
        }
        if (count == MAX_ARGS - 1) {
            return -1;
        }
        job_argv[count++] = p;
        while (*p != 0 && *p != ' ' && *p != '\t') {
            p++;
        }
        if (*p != 0) {
            *p++ = 0;
        }
    }
    job_argv[count] = NULL;
    return count;
}

static int read_batch(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[MAX_LINE];

    if (f == NULL) {
        fprintf(stderr, "prun: cannot open %s\n", path);
        return -1;
    }

    while (fgets(line, sizeof(line), f) != NULL) {
        size_t len = strlen(line);
        char *copy;

        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
            line[--len] = 0;
        }
        if (len == 0 || line[0] == '#') {
            continue;
        }
        if (command_count == MAX_JOBS) {
            fprintf(stderr, "prun: more than %d commands\n", MAX_JOBS);
            fclose(f);
            return -1;
        }
        copy = arena_dup(line, len);
        if (copy == NULL) {
            fprintf(stderr, "prun: batch text exceeds %d bytes\n", ARENA_BYTES);
            fclose(f);
            return -1;
        }
        commands[command_count++] = copy;
    }

    fclose(f);
    return 0;
}

/*
 * Start one job. Returns its pid, or -1 if it could not be started. argv and
 * envp are built here, in this process's own memory, never from `environ`.
 */
static pid_t spawn(int job)
{
    static char *envp[1];
    pid_t pid;
    int n;

    n = split_args(commands[job]);
    if (n <= 0) {
        return -1;
    }
    envp[0] = NULL;

    /*
     * Built before the vfork, in the parent: the child must do as little as
     * possible, and snprintf into a shared buffer from a vforked child would be
     * writing to the parent's memory.
     */
    snprintf(logpath, sizeof(logpath), "%s/%d.log", logdir, job);

    pid = vfork();
    if (pid == 0) {
        int fd = open(logpath, O_WRONLY | O_CREAT | O_TRUNC, 0644);

        if (fd >= 0) {
            dup2(fd, 1);
            dup2(fd, 2);
            close(fd);
        }
        execve(job_argv[0], job_argv, envp);
        /*
         * Only reached if exec failed. _exit, not exit: this is still sharing
         * the parent's memory, and a normal exit would run its atexit handlers
         * and flush its streams.
         */
        _exit(127);
    }
    return pid;
}

/* Wait for one child to finish and report it. Returns 0, or -1 if none left. */
static int reap_one(void)
{
    int status = 0;
    pid_t done;
    int slot;
    int job = -1;
    int code;

    if (running_count == 0) {
        return -1;
    }

    done = waitpid(-1, &status, 0);
    if (done < 0) {
        /*
         * No child to wait for, though we think some are running: report the
         * survivors rather than looping forever on an error we cannot clear.
         */
        for (slot = 0; slot < running_count; slot++) {
            printf("PRUN %d -1\n", running_job[slot]);
        }
        fflush(stdout);
        running_count = 0;
        return -1;
    }

    for (slot = 0; slot < running_count; slot++) {
        if (running_pid[slot] == done) {
            job = running_job[slot];
            running_pid[slot] = running_pid[running_count - 1];
            running_job[slot] = running_job[running_count - 1];
            running_count--;
            break;
        }
    }
    if (job < 0) {
        /* Someone else's child; nothing to attribute it to. */
        return 0;
    }

    if (WIFEXITED(status)) {
        code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        code = 128 + WTERMSIG(status);
    } else {
        code = -1;
    }

    printf("PRUN %d %d\n", job, code);
    fflush(stdout);
    return 0;
}

int main(int argc, char **argv)
{
    int parallel = DEFAULT_PARALLEL;
    const char *batch = NULL;
    int next = 0;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-j") == 0 && i + 1 < argc) {
            parallel = atoi(argv[++i]);
            if (parallel < 1) {
                parallel = 1;
            }
            if (parallel > MAX_JOBS) {
                parallel = MAX_JOBS;
            }
        } else if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            snprintf(logdir, sizeof(logdir), "%s", argv[++i]);
        } else {
            batch = argv[i];
        }
    }

    if (batch == NULL) {
        fprintf(stderr, "usage: prun [-j N] [-o LOGDIR] <batchfile>\n");
        return 2;
    }
    if (read_batch(batch) != 0) {
        return 2;
    }

    while (next < command_count || running_count > 0) {
        while (next < command_count && running_count < parallel) {
            pid_t pid = spawn(next);

            if (pid < 0) {
                printf("PRUN %d -1\n", next);
                fflush(stdout);
            } else {
                running_pid[running_count] = pid;
                running_job[running_count] = next;
                running_count++;
            }
            next++;
        }
        if (reap_one() != 0 && running_count == 0 && next >= command_count) {
            break;
        }
    }

    printf("PRUN_DONE %d\n", command_count);
    fflush(stdout);
    return 0;
}
