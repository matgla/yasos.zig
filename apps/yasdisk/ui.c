/*
 Copyright (c) 2025 Mateusz Stadnik

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

#include "ui.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Type selection list
static const struct {
    uint8_t type;
    const char* name;
} partition_types[] = {
    {PART_TYPE_EMPTY, "Empty"},
    {PART_TYPE_FAT12, "FAT12"},
    {PART_TYPE_FAT16_S, "FAT16 (<32MB)"},
    {PART_TYPE_FAT16_L, "FAT16 (>=32MB)"},
    {PART_TYPE_NTFS, "NTFS/exFAT"},
    {PART_TYPE_FAT32, "FAT32"},
    {PART_TYPE_FAT32_LBA, "FAT32 (LBA)"},
    {PART_TYPE_FAT16_LBA, "FAT16 (LBA)"},
    {PART_TYPE_LINUX_SWAP, "Linux swap"},
    {PART_TYPE_LINUX, "Linux"},
    {PART_TYPE_LINUX_LVM, "Linux LVM"},
    {PART_TYPE_FREEBSD, "FreeBSD"},
    {PART_TYPE_OPENBSD, "OpenBSD"},
    {PART_TYPE_NETBSD, "NetBSD"},
    {PART_TYPE_GPT, "GPT protective"},
    {PART_TYPE_EFI, "EFI System"},
    {0x0F, "Extended (LBA)"},
    {0x05, "Extended"},
    {0x82, "Linux swap / Solaris"},
};
#define NUM_PARTITION_TYPES (sizeof(partition_types) / sizeof(partition_types[0]))

// Screen dimensions
static int screen_cols = 80;
static int screen_lines = 25;

static void update_screen_size(void) {
    getmaxyx(stdscr, screen_lines, screen_cols);
}

void ui_init(void) {
    initscr();
    cbreak();
    noecho();
    keypad(stdscr, 1);
    curs_set(0);
    update_screen_size();

    start_color();
    init_pair(UI_COLOR_DEFAULT, COLOR_WHITE, COLOR_BLACK);
    init_pair(UI_COLOR_HIGHLIGHT, COLOR_BLACK, COLOR_WHITE);
    init_pair(UI_COLOR_HEADER, COLOR_CYAN, COLOR_BLACK);
    init_pair(UI_COLOR_WARNING, COLOR_YELLOW, COLOR_BLACK);
    init_pair(UI_COLOR_SUCCESS, COLOR_GREEN, COLOR_BLACK);
}

void ui_cleanup(void) {
    endwin();
}

void ui_run(Disk* disk) {
    UIContext ctx = {0};
    ctx.state = UI_STATE_MAIN;
    ctx.selected_partition = 0;
    ctx.running = 1;
    ctx.edit_field = 0;

    // Clear any initial message
    ctx.message[0] = '\0';

    while (ctx.running) {
        clear();
        update_screen_size();

        switch (ctx.state) {
            case UI_STATE_MAIN:
                ui_draw_main(&ctx, disk);
                break;
            case UI_STATE_EDIT_PARTITION:
                ui_draw_edit_dialog(&ctx, disk);
                break;
            case UI_STATE_CONFIRM_WRITE:
                ui_draw_confirm_dialog(&ctx, "Write changes to disk? (All data will be lost!)");
                break;
            case UI_STATE_QUIT_CONFIRM:
                ui_draw_confirm_dialog(&ctx, disk->dirty
                    ? "Quit without saving changes?"
                    : "Quit yasdisk?");
                break;
            case UI_STATE_HELP:
                ui_draw_help_screen(&ctx);
                break;
            case UI_STATE_TYPE_SELECT:
                ui_draw_type_select(&ctx);
                break;
        }

        refresh();
        ui_handle_input(&ctx, disk);
    }
}

void ui_draw_header(const Disk* disk) {
    attron(COLOR_PAIR(UI_COLOR_HEADER) | A_BOLD);
    mvaddstr(0, 0, "yasdisk - MBR Partition Editor");
    attroff(COLOR_PAIR(UI_COLOR_HEADER) | A_BOLD);

    // Device info
    char size_str[32];
    format_size(disk->device_size, size_str, sizeof(size_str));
    mvprintw(1, 0, "Device: %s  Size: %s  Sector: %u bytes",
             disk->device_path, size_str, disk->sector_size);

    // Draw line
    attron(A_BOLD);
    for (int i = 0; i < screen_cols; i++) {
        mvaddch(2, i, '-');
    }
    attroff(A_BOLD);
}

void ui_draw_partition_list(UIContext* ctx, const Disk* disk, int row) {
    const char* headers[] = {"Device", "Boot", "Start", "End", "Sectors", "Size", "Type"};
    int col_widths[] = {8, 6, 12, 12, 12, 10, 16};

    // Draw headers
    attron(A_BOLD | COLOR_PAIR(UI_COLOR_HEADER));
    int col = 2;
    for (int i = 0; i < 7; i++) {
        mvprintw(row, col, "%*s", col_widths[i], headers[i]);
        col += col_widths[i] + 1;
    }
    attroff(A_BOLD | COLOR_PAIR(UI_COLOR_HEADER));

    row++;

    // Draw partitions
    for (int i = 0; i < MBR_PARTITION_COUNT; i++) {
        const PartitionEntry* pe = &disk->mbr.partitions[i];

        if (i == ctx->selected_partition && ctx->state == UI_STATE_MAIN) {
            attron(COLOR_PAIR(UI_COLOR_HIGHLIGHT));
        }

        char device[16];
        snprintf(device, sizeof(device), "%s%d", disk->device_path, i + 1);

        col = 2;
        mvprintw(row + i, col, "%-*s", col_widths[0], device);
        col += col_widths[0] + 1;

        if (partition_is_empty(pe)) {
            mvprintw(row + i, col, "%-*s", col_widths[1], "");
            col += col_widths[1] + 1;
            mvprintw(row + i, col, "%-*s", col_widths[2], "-");
            col += col_widths[2] + 1;
            mvprintw(row + i, col, "%-*s", col_widths[3], "-");
            col += col_widths[3] + 1;
            mvprintw(row + i, col, "%-*s", col_widths[4], "-");
            col += col_widths[4] + 1;
            mvprintw(row + i, col, "%-*s", col_widths[5], "-");
            col += col_widths[5] + 1;
            mvprintw(row + i, col, "%-*s", col_widths[6], "Free Space");
        } else {
            char size_str[16];
            uint64_t bytes = (uint64_t)pe->sector_count * disk->sector_size;
            format_size(bytes, size_str, sizeof(size_str));

            uint32_t end_lba = pe->start_lba + pe->sector_count - 1;

            mvprintw(row + i, col, "%-*s", col_widths[1],
                     partition_is_bootable(pe) ? "*" : "");
            col += col_widths[1] + 1;
            mvprintw(row + i, col, "%-*u", col_widths[2], pe->start_lba);
            col += col_widths[2] + 1;
            mvprintw(row + i, col, "%-*u", col_widths[3], end_lba);
            col += col_widths[3] + 1;
            mvprintw(row + i, col, "%-*u", col_widths[4], pe->sector_count);
            col += col_widths[4] + 1;
            mvprintw(row + i, col, "%-*s", col_widths[5], size_str);
            col += col_widths[5] + 1;
            mvprintw(row + i, col, "%-*s", col_widths[6],
                     partition_get_type_name(pe->type));
        }

        if (i == ctx->selected_partition && ctx->state == UI_STATE_MAIN) {
            attroff(COLOR_PAIR(UI_COLOR_HIGHLIGHT));
        }
    }
}

void ui_draw_footer(UIContext* ctx, const Disk* disk) {
    int row = screen_lines - 2;

    // Draw line
    attron(A_BOLD);
    for (int i = 0; i < screen_cols; i++) {
        mvaddch(row - 1, i, '-');
    }
    attroff(A_BOLD);

    // Commands
    attron(A_BOLD);
    mvaddstr(row, 0, "n=New d=Delete a=Boot t=Type w=Write q=Quit ?=Help");
    attroff(A_BOLD);

    // Message or dirty indicator
    if (ctx->message[0] != '\0') {
        int color = UI_COLOR_DEFAULT;
        if (ctx->message_type == 1) color = UI_COLOR_WARNING;
        if (ctx->message_type == 2) color = UI_COLOR_SUCCESS;
        attron(COLOR_PAIR(color));
        mvaddstr(row + 1, 0, ctx->message);
        attroff(COLOR_PAIR(color));
    } else if (disk && disk->dirty) {
        attron(COLOR_PAIR(UI_COLOR_WARNING));
        mvaddstr(row + 1, 0, "* Unsaved changes");
        attroff(COLOR_PAIR(UI_COLOR_WARNING));
    }
}

void ui_draw_main(UIContext* ctx, Disk* disk) {
    ui_draw_header(disk);
    ui_draw_partition_list(ctx, disk, 4);
    ui_draw_footer(ctx, disk);
}

void ui_draw_edit_dialog(UIContext* ctx, Disk* disk) {
    ui_draw_header(disk);
    ui_draw_partition_list(ctx, disk, 4);

    // Draw dialog box
    int dlg_height = 10;
    int dlg_width = 50;
    int dlg_y = (screen_lines - dlg_height) / 2;
    int dlg_x = (screen_cols - dlg_width) / 2;

    WINDOW* dlg = newwin(dlg_height, dlg_width, dlg_y, dlg_x);
    box(dlg, 0, 0);
    mvwprintw(dlg, 0, 2, " New Partition %d ", ctx->selected_partition + 1);

    // Fields
    const char* labels[] = {"Start sector:", "Size (sectors):", "Type:"};
    int values_y = 2;

    for (int i = 0; i < 3; i++) {
        mvwaddstr(dlg, values_y + i * 2, 2, labels[i]);

        if (i == ctx->edit_field) {
            wattron(dlg, COLOR_PAIR(UI_COLOR_HIGHLIGHT));
        }

        if (i == 0) {
            mvwprintw(dlg, values_y + i * 2, 20, "%u", ctx->edit_start);
        } else if (i == 1) {
            mvwprintw(dlg, values_y + i * 2, 20, "%u", ctx->edit_size);
        } else {
            mvwprintw(dlg, values_y + i * 2, 20, "0x%02X (%s)",
                     ctx->edit_type, partition_get_type_name(ctx->edit_type));
        }

        if (i == ctx->edit_field) {
            wattroff(dlg, COLOR_PAIR(UI_COLOR_HIGHLIGHT));
        }
    }

    mvwaddstr(dlg, dlg_height - 2, 2, "Enter=Accept  q=Cancel");

    wrefresh(dlg);
    // Note: delwin not available in simplified curses, just move cursor away
    wmove(stdscr, 0, 0);
}

void ui_draw_confirm_dialog(UIContext* ctx, const char* message) {
    (void)ctx;
    int dlg_height = 7;
    int dlg_width = strlen(message) + 8;
    if (dlg_width < 40) dlg_width = 40;
    int dlg_y = (screen_lines - dlg_height) / 2;
    int dlg_x = (screen_cols - dlg_width) / 2;

    WINDOW* dlg = newwin(dlg_height, dlg_width, dlg_y, dlg_x);
    box(dlg, 0, 0);

    wattron(dlg, COLOR_PAIR(UI_COLOR_WARNING) | A_BOLD);
    mvwaddstr(dlg, 2, (dlg_width - strlen(message)) / 2, message);
    wattroff(dlg, COLOR_PAIR(UI_COLOR_WARNING) | A_BOLD);

    mvwaddstr(dlg, dlg_height - 2, (dlg_width - 18) / 2, "y=Yes  n=No");

    wrefresh(dlg);
    wmove(stdscr, 0, 0);
}

void ui_draw_help_screen(UIContext* ctx) {
    (void)ctx;

    const char* help_text[] = {
        "yasdisk - MBR Partition Editor Help",
        "",
        "Navigation:",
        "  Up/Down, k/j    Move between partitions",
        "",
        "Commands:",
        "  n               Create new partition",
        "  d               Delete selected partition",
        "  a               Toggle bootable flag",
        "  t               Change partition type",
        "  w               Write changes to disk",
        "  q               Quit",
        "  ?               Show this help",
        "",
        "In Edit Dialog:",
        "  Tab/Up/Down     Move between fields",
        "  Enter           Accept changes",
        "  q/Esc           Cancel",
        "",
        "Press any key to return..."
    };

    int num_lines = sizeof(help_text) / sizeof(help_text[0]);
    int start_y = (screen_lines - num_lines) / 2;

    // Draw box
    int box_width = 50;
    int box_height = num_lines + 2;
    int box_x = (screen_cols - box_width) / 2;

    WINDOW* win = newwin(box_height, box_width, start_y - 1, box_x);
    box(win, 0, 0);
    wrefresh(win);
    wmove(stdscr, 0, 0);

    attron(COLOR_PAIR(UI_COLOR_HEADER) | A_BOLD);
    mvaddstr(start_y, (screen_cols - strlen(help_text[0])) / 2, help_text[0]);
    attroff(COLOR_PAIR(UI_COLOR_HEADER) | A_BOLD);

    for (int i = 1; i < num_lines; i++) {
        mvaddstr(start_y + i, box_x + 2, help_text[i]);
    }
}

void ui_draw_type_select(UIContext* ctx) {
    int dlg_height = 16;
    int dlg_width = 40;
    int dlg_y = (screen_lines - dlg_height) / 2;
    int dlg_x = (screen_cols - dlg_width) / 2;

    WINDOW* dlg = newwin(dlg_height, dlg_width, dlg_y, dlg_x);
    box(dlg, 0, 0);
    mvwaddstr(dlg, 0, 2, " Select Type ");

    int visible_items = dlg_height - 3;
    int selected_idx = 0;

    // Find selected type index
    for (size_t i = 0; i < NUM_PARTITION_TYPES; i++) {
        if (partition_types[i].type == ctx->edit_type) {
            selected_idx = i;
            break;
        }
    }

    // Adjust scroll
    if (selected_idx < ctx->type_scroll) {
        ctx->type_scroll = selected_idx;
    } else if (selected_idx >= ctx->type_scroll + visible_items) {
        ctx->type_scroll = selected_idx - visible_items + 1;
    }

    for (int i = 0; i < visible_items && (size_t)(ctx->type_scroll + i) < NUM_PARTITION_TYPES; i++) {
        int idx = ctx->type_scroll + i;
        if (partition_types[idx].type == ctx->edit_type) {
            wattron(dlg, COLOR_PAIR(UI_COLOR_HIGHLIGHT));
        }
        mvwprintw(dlg, 1 + i, 2, "0x%02X %s",
                 partition_types[idx].type, partition_types[idx].name);
        if (partition_types[idx].type == ctx->edit_type) {
            wattroff(dlg, COLOR_PAIR(UI_COLOR_HIGHLIGHT));
        }
    }

    mvwaddstr(dlg, dlg_height - 1, 2, "Enter=Select q=Cancel");

    wrefresh(dlg);
    wmove(stdscr, 0, 0);
}

void ui_handle_input(UIContext* ctx, Disk* disk) {
    int ch = getch();

    switch (ctx->state) {
        case UI_STATE_MAIN:
            ui_handle_main_input(ctx, disk, ch);
            break;
        case UI_STATE_EDIT_PARTITION:
            ui_handle_edit_input(ctx, disk, ch);
            break;
        case UI_STATE_CONFIRM_WRITE:
        case UI_STATE_QUIT_CONFIRM:
            ui_handle_confirm_input(ctx, disk, ch);
            break;
        case UI_STATE_HELP:
            ctx->state = UI_STATE_MAIN;
            break;
        case UI_STATE_TYPE_SELECT:
            ui_handle_type_select_input(ctx, disk, ch);
            break;
    }
}

void ui_handle_main_input(UIContext* ctx, Disk* disk, int ch) {
    ui_clear_message(ctx);

    switch (ch) {
        case KEY_UP:
        case 'k':
            if (ctx->selected_partition > 0) {
                ctx->selected_partition--;
            }
            break;
        case KEY_DOWN:
        case 'j':
            if (ctx->selected_partition < MBR_PARTITION_COUNT - 1) {
                ctx->selected_partition++;
            }
            break;
        case 'n':
            // New partition
            if (!partition_is_empty(&disk->mbr.partitions[ctx->selected_partition])) {
                ui_set_message(ctx, 1, "Partition already exists, delete first");
            } else {
                ui_get_partition_defaults(disk, &ctx->edit_start, &ctx->edit_size);
                ctx->edit_type = PART_TYPE_LINUX;
                ctx->edit_field = 0;
                ctx->state = UI_STATE_EDIT_PARTITION;
            }
            break;
        case 'd':
            // Delete partition
            if (partition_is_empty(&disk->mbr.partitions[ctx->selected_partition])) {
                ui_set_message(ctx, 1, "Partition is already empty");
            } else {
                partition_delete(disk, ctx->selected_partition);
                ui_set_message(ctx, 0, "Partition deleted (not yet written)");
            }
            break;
        case 'a':
            // Toggle bootable
            if (partition_is_empty(&disk->mbr.partitions[ctx->selected_partition])) {
                ui_set_message(ctx, 1, "No partition to modify");
            } else {
                int bootable = !partition_is_bootable(&disk->mbr.partitions[ctx->selected_partition]);
                partition_set_bootable(&disk->mbr.partitions[ctx->selected_partition], bootable);
                disk->dirty = 1;
                ui_set_message(ctx, 0, bootable ? "Partition marked bootable" : "Boot flag removed");
            }
            break;
        case 't':
            // Change type
            if (partition_is_empty(&disk->mbr.partitions[ctx->selected_partition])) {
                ui_set_message(ctx, 1, "No partition to modify");
            } else {
                ctx->edit_type = disk->mbr.partitions[ctx->selected_partition].type;
                ctx->type_scroll = 0;
                ctx->state = UI_STATE_TYPE_SELECT;
            }
            break;
        case 'w':
            // Write to disk
            if (!disk->dirty) {
                ui_set_message(ctx, 1, "No changes to write");
            } else {
                ctx->state = UI_STATE_CONFIRM_WRITE;
            }
            break;
        case 'q':
            ctx->state = UI_STATE_QUIT_CONFIRM;
            break;
        case '?':
            ctx->state = UI_STATE_HELP;
            break;
    }
}

void ui_handle_edit_input(UIContext* ctx, Disk* disk, int ch) {
    (void)disk;

    switch (ch) {
        case KEY_UP:
            if (ctx->edit_field > 0) {
                ctx->edit_field--;
            }
            break;
        case KEY_DOWN:
        case '\t':
            if (ctx->edit_field < 2) {
                ctx->edit_field++;
            }
            break;
        case 'q':
        case 27: // ESC
            ctx->state = UI_STATE_MAIN;
            ui_set_message(ctx, 1, "Cancelled");
            break;
        case '\n':
            // Validate and create partition
            if (ctx->edit_size == 0) {
                ui_set_message(ctx, 1, "Size must be greater than 0");
                ctx->state = UI_STATE_MAIN;
            } else if (ctx->edit_start < 2048) {
                ui_set_message(ctx, 1, "Start sector must be >= 2048 (1MB alignment)");
                ctx->state = UI_STATE_MAIN;
            } else {
                int result = partition_create(disk, ctx->selected_partition,
                                             ctx->edit_start, ctx->edit_size,
                                             ctx->edit_type);
                if (result == 0) {
                    ui_set_message(ctx, 0, "Partition created (not yet written)");
                } else {
                    ui_set_message(ctx, 1, "Failed to create partition (check bounds/overlap)");
                }
                ctx->state = UI_STATE_MAIN;
            }
            break;
        default:
            // Handle number input for fields
            if (ch >= '0' && ch <= '9') {
                int digit = ch - '0';
                if (ctx->edit_field == 0) {
                    ctx->edit_start = ctx->edit_start * 10 + digit;
                } else if (ctx->edit_field == 1) {
                    ctx->edit_size = ctx->edit_size * 10 + digit;
                }
            } else if (ch == KEY_BACKSPACE || ch == 127 || ch == '\b') {
                if (ctx->edit_field == 0) {
                    ctx->edit_start /= 10;
                } else if (ctx->edit_field == 1) {
                    ctx->edit_size /= 10;
                }
            }
            break;
    }
}

void ui_handle_confirm_input(UIContext* ctx, Disk* disk, int ch) {
    if (ch == 'y' || ch == 'Y') {
        if (ctx->state == UI_STATE_CONFIRM_WRITE) {
            if (disk_write_mbr(disk) == 0) {
                ui_set_message(ctx, 2, "Changes written to disk");
            } else {
                ui_set_message(ctx, 1, "Failed to write to disk");
            }
            ctx->state = UI_STATE_MAIN;
        } else if (ctx->state == UI_STATE_QUIT_CONFIRM) {
            ctx->running = 0;
        }
    } else if (ch == 'n' || ch == 'N' || ch == 'q' || ch == 27) {
        ctx->state = UI_STATE_MAIN;
    }
}

void ui_handle_type_select_input(UIContext* ctx, Disk* disk, int ch) {
    int selected_idx = 0;
    for (size_t i = 0; i < NUM_PARTITION_TYPES; i++) {
        if (partition_types[i].type == ctx->edit_type) {
            selected_idx = i;
            break;
        }
    }

    switch (ch) {
        case KEY_UP:
        case 'k':
            if (selected_idx > 0) {
                ctx->edit_type = partition_types[selected_idx - 1].type;
            }
            break;
        case KEY_DOWN:
        case 'j':
            if ((size_t)selected_idx < NUM_PARTITION_TYPES - 1) {
                ctx->edit_type = partition_types[selected_idx + 1].type;
            }
            break;
        case '\n':
            disk->mbr.partitions[ctx->selected_partition].type = ctx->edit_type;
            disk->dirty = 1;
            ui_set_message(ctx, 0, "Type changed (not yet written)");
            ctx->state = UI_STATE_MAIN;
            break;
        case 'q':
        case 27:
            ctx->state = UI_STATE_MAIN;
            break;
    }
}

void ui_set_message(UIContext* ctx, int type, const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(ctx->message, sizeof(ctx->message), fmt, args);
    va_end(args);
    ctx->message_type = type;
}

void ui_clear_message(UIContext* ctx) {
    ctx->message[0] = '\0';
    ctx->message_type = 0;
}

void ui_get_partition_defaults(const Disk* disk, uint32_t* start, uint32_t* size) {
    // Find the highest used sector
    uint64_t max_used = 2048;  // Start at 1MB

    for (int i = 0; i < MBR_PARTITION_COUNT; i++) {
        const PartitionEntry* pe = &disk->mbr.partitions[i];
        if (!partition_is_empty(pe)) {
            uint64_t end = (uint64_t)pe->start_lba + pe->sector_count;
            if (end > max_used) {
                max_used = end;
            }
        }
    }

    // Align to 1MB boundary
    *start = (uint32_t)align_sector(max_used);

    // Calculate available space
    uint64_t max_sectors = disk->device_size / disk->sector_size;
    if (*start < max_sectors) {
        uint64_t available = max_sectors - *start;
        // Leave some space, but cap at reasonable size for uint32_t
        if (available > 0xFFFFFFFFULL) {
            available = 0xFFFFFFFFULL;
        }
        *size = (uint32_t)available;
    } else {
        *size = 0;
    }
}
