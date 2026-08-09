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

#ifndef YASDISK_UI_H
#define YASDISK_UI_H

#include "mbr.h"

#include <ncurses.h>

// UI colors
#define UI_COLOR_DEFAULT    1
#define UI_COLOR_HIGHLIGHT  2
#define UI_COLOR_HEADER     3
#define UI_COLOR_WARNING    4
#define UI_COLOR_SUCCESS    5

// UI states
typedef enum {
    UI_STATE_MAIN,
    UI_STATE_EDIT_PARTITION,
    UI_STATE_CONFIRM_WRITE,
    UI_STATE_HELP,
    UI_STATE_QUIT_CONFIRM,
    UI_STATE_TYPE_SELECT
} UIState;

typedef struct {
    UIState state;
    int selected_partition;
    int running;
    int show_help;
    char message[256];
    int message_type;  // 0 = info, 1 = warning, 2 = error

    // Edit dialog
    uint32_t edit_start;
    uint32_t edit_size;
    uint8_t edit_type;
    int edit_field;

    // Type selection
    int type_scroll;
} UIContext;

// Initialization and cleanup
void ui_init(void);
void ui_cleanup(void);

// Main UI functions
void ui_run(Disk* disk);
void ui_draw_main(UIContext* ctx, Disk* disk);
void ui_draw_header(const Disk* disk);
void ui_draw_partition_list(UIContext* ctx, const Disk* disk, int row);
void ui_draw_footer(UIContext* ctx, const Disk* disk);

// Dialog functions
void ui_draw_edit_dialog(UIContext* ctx, Disk* disk);
void ui_draw_confirm_dialog(UIContext* ctx, const char* message);
void ui_draw_help_screen(UIContext* ctx);
void ui_draw_type_select(UIContext* ctx);

// Input handling
void ui_handle_input(UIContext* ctx, Disk* disk);
void ui_handle_main_input(UIContext* ctx, Disk* disk, int ch);
void ui_handle_edit_input(UIContext* ctx, Disk* disk, int ch);
void ui_handle_confirm_input(UIContext* ctx, Disk* disk, int ch);
void ui_handle_type_select_input(UIContext* ctx, Disk* disk, int ch);

// Utility
void ui_set_message(UIContext* ctx, int type, const char* fmt, ...);
void ui_clear_message(UIContext* ctx);
void ui_get_partition_defaults(const Disk* disk, uint32_t* start, uint32_t* size);

#endif // YASDISK_UI_H
