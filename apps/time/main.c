/*
 * time -- how long a command took, by the clock on the wall.
 *
 * Copyright (c) 2026 Mateusz Stadnik
 *
 * The board can already compile a program and run it.  What it could not do
 * was say how long the run took, which is the one thing a demo about
 * *instruction selection* has to be able to say out loud: two kernels that
 * return the same checksum, and one of them takes twice as long.  Without a
 * clock that argument is a claim about a listing; with one it is a
 * measurement the camera can read off the screen.
 *
 * ## Only `real`, and that is not a shortcut
 *
 * POSIX `time` prints three numbers.  This prints one, because one is all this
 * kernel knows: `sys_times` is a stub that returns -1
 * (source/kernel/interrupts/syscall_handlers.zig) and there is no per-process
 * CPU accounting behind it, so `user` and `sys` could only be printed as two
 * zeroes.  Two zeroes on camera are worse than no line at all -- they read as
 * a measurement, and they are furniture.  The clock that does exist is
 * `gettimeofday`, which the kernel answers from `hal.time.get_time_us()`: a
 * free-running microsecond counter since boot, which is exactly the right
 * clock for "how long did that take".
 *
 * Elapsed time is kept as separate seconds and microseconds rather than
 * multiplied into one number.  `long` is 32 bits here, so `tv_sec * 1000000`
 * wraps after 71 minutes of uptime -- and a recording session runs longer than
 * that, so the bug would show up on the take rather than on the bench.
 *
 * ## Three things vfork forces, all of them established by apps/prun
 *
 *  - **Never pass `environ` to exec**, which rules out `execvp` and `execv`:
 *    both hand the syscall whatever `environ` points at, and only `execve`
 *    lets the caller name an environment it built itself.  The child here gets
 *    an empty one.
 *
 *  - **The argv the child execs with is built in this program's own static
 *    storage**, copied out of the argv `main` was handed.  A user process's
 *    `malloc` returns memory the kernel's `uaccess` check refuses to read on
 *    behalf of a syscall, and static storage is part of the process image,
 *    which it accepts.  Copying costs a memcpy of the command line once; not
 *    copying costs an EFAULT that only appears on the device.
 *
 *  - **The child does as little as possible before `execve`**, and leaves with
 *    `_exit` rather than `exit`.  Until the exec it is still writing to the
 *    parent's memory, and a normal exit would run the parent's atexit handlers
 *    and flush the parent's streams.
 *
 * ## And PATH is searched here
 *
 * `execve` takes a path, not a command name, so `time ls` has to become
 * `execve("/bin/ls", ...)` before the child starts.  The search is this
 * program's because the obvious alternative -- exec `sh -c` and let the shell
 * do it -- HardFaults this kernel from a vforked child (apps/prun).
 *
 * Usage:
 *   time [-p] COMMAND [ARG...]
 *
 *   -p   POSIX output: `real 1.23` on one line, seconds with two decimals.
 *
 * Exit status is the command's own, or 127 if it could not be found, 126 if it
 * was found and could not be run, and 1 for a usage error -- which is what a
 * shell expects of anything that runs something else.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAX_ARGS 64
#define ARENA_BYTES 1024
#define PATH_MAX_LEN 256

/* Where the PATH search looks when the environment does not say.  /bin and
 * /usr/bin hold the same set on this rootfs; both are listed so a stripped
 * image with only one of them still works. */
#define DEFAULT_PATH "/bin:/usr/bin"

/*
 * The child's argv, and the strings it points at.  Static rather than malloc'd
 * for the reason in the header: this is what execve is allowed to read.
 */
static char arena[ARENA_BYTES];
static size_t arena_used;
static char *child_argv[MAX_ARGS + 1];
static char *child_envp[1];
static char program[PATH_MAX_LEN];

static char *arena_dup(const char *text)
{
    size_t len = strlen(text) + 1;
    char *out;

    if (arena_used + len > sizeof(arena)) {
        return NULL;
    }
    out = arena + arena_used;
    memcpy(out, text, len);
    arena_used += len;
    return out;
}

/*
 * Fill `program` with the file to exec, or leave it empty when there is no
 * such command.  A name with a slash in it is a path already and is taken as
 * written -- including `./demo`, which is how the demo runs what it just
 * compiled.
 */
static int resolve(const char *name)
{
    const char *path = getenv("PATH");
    const char *dir;

    if (strchr(name, '/') != NULL) {
        if (strlen(name) >= sizeof(program)) {
            return -1;
        }
        strcpy(program, name);
        return access(program, F_OK) == 0 ? 0 : -1;
    }

    if (path == NULL || *path == '\0') {
        path = DEFAULT_PATH;
    }

    for (dir = path; dir != NULL; ) {
        const char *end = strchr(dir, ':');
        size_t len = end != NULL ? (size_t)(end - dir) : strlen(dir);

        if (len > 0 && len + 1 + strlen(name) < sizeof(program)) {
            memcpy(program, dir, len);
            program[len] = '/';
            strcpy(program + len + 1, name);
            if (access(program, F_OK) == 0) {
                return 0;
            }
        }
        dir = end != NULL ? end + 1 : NULL;
    }

    program[0] = '\0';
    return -1;
}

/*
 * `after - before`, as whole seconds plus a microsecond remainder.  Never as
 * one integer of microseconds: see the header.
 */
static void elapsed(const struct timeval *before, const struct timeval *after,
                    long *sec, long *usec)
{
    *sec = (long)(after->tv_sec - before->tv_sec);
    *usec = (long)(after->tv_usec - before->tv_usec);
    if (*usec < 0) {
        *usec += 1000000;
        *sec -= 1;
    }
}

int main(int argc, char *argv[])
{
    struct timeval before, after;
    long sec = 0, usec = 0;
    int posix = 0;
    int first = 1;
    int status = 0;
    int n;
    pid_t pid;

    if (first < argc && strcmp(argv[first], "-p") == 0) {
        posix = 1;
        first++;
    }

    if (first >= argc) {
        fprintf(stderr, "usage: time [-p] COMMAND [ARG...]\n");
        return 1;
    }

    if (resolve(argv[first]) != 0) {
        fprintf(stderr, "time: %s: not found\n", argv[first]);
        return 127;
    }

    /* Built before the vfork, in the parent: the child must touch as little as
     * possible, and everything it writes before the exec it writes into the
     * parent's memory. */
    for (n = 0; first + n < argc; n++) {
        if (n >= MAX_ARGS) {
            fprintf(stderr, "time: too many arguments (max %d)\n", MAX_ARGS);
            return 1;
        }
        child_argv[n] = arena_dup(argv[first + n]);
        if (child_argv[n] == NULL) {
            fprintf(stderr, "time: command line too long\n");
            return 1;
        }
    }
    child_argv[n] = NULL;
    child_envp[0] = NULL;

    /* Whatever this program still has buffered belongs before the command's
     * own output, not interleaved with it after the exec. */
    fflush(NULL);

    gettimeofday(&before, NULL);
    pid = vfork();
    if (pid < 0) {
        fprintf(stderr, "time: cannot start %s\n", program);
        return 126;
    }
    if (pid == 0) {
        execve(program, child_argv, child_envp);
        _exit(126);
    }

    if (waitpid(pid, &status, 0) < 0) {
        gettimeofday(&after, NULL);
        fprintf(stderr, "time: lost track of %s\n", program);
        return 126;
    }
    gettimeofday(&after, NULL);

    elapsed(&before, &after, &sec, &usec);

    /* stderr, so a `time cmd > file` still shows the number and the file still
     * holds only what the command wrote. */
    if (posix) {
        fprintf(stderr, "real %ld.%02ld\n", sec, usec / 10000);
    } else {
        fprintf(stderr, "\nreal\t%ld.%03lds\n", sec, usec / 1000);
    }
    fflush(stderr);

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return 128 + WTERMSIG(status);
}
