/**
 * executable.ld
 *
 * Copyright (C) 2023 Mateusz Stadnik <matgla@live.com>
 *
 * This program is free software: you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation, either version
 * 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be
 * useful, but WITHOUT ANY WARRANTY; without even the implied
 * warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 * PURPOSE. See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General
 * Public License along with this program. If not, see
 * <https://www.gnu.org/licenses/>.
 */

MEMORY
{
  image(rwx) : ORIGIN = 0x00000000, LENGTH = 0xffffffff
}

PHDRS
{
  text PT_LOAD;
  data  PT_LOAD;
}


SECTIONS
{
  .text :
  {
    . = ALIGN(16);
    KEEP(*(.entry))
    *(.text)
    *(.text*)
    *(.glue_7)
    *(.glue_7t)
    *(.eh_frame)
    KEEP(*(.init))
    KEEP(*(.fini))
    *(.rodata)
    *(.rodata*)
    . = ALIGN(16);
  } > image :text

  .init_arrays :
  {
    . = ALIGN(16); 
    PROVIDE_HIDDEN(__preinit_array_start = .);
    KEEP(*(.preinit_array.*))
    KEEP(*(.preinit_array))
    PROVIDE_HIDDEN(__preinit_array_end = .);
    . = ALIGN(16); 
    PROVIDE_HIDDEN(__init_array_start = .);
    KEEP(*(.init_array.*))
    KEEP(*(.init_array))
    PROVIDE_HIDDEN(__init_array_end = .);
    . = ALIGN(16);
    PROVIDE_HIDDEN(__fini_array_start = .);
    KEEP(*(.fini_array.*))
    KEEP(*(.fini_array))
    PROVIDE_HIDDEN(__fini_array_end = .);
    . = ALIGN(16);
  } > image :text


  .plt :
  {
    *(.plt*)
  } > image :text

  .data :
  {
    . = ALIGN(16);
    *(.data)
    *(.data*)
    . = ALIGN(16);
  } > image :data

  .bss :
  {
    . = ALIGN(4);
    *(.bss)
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
  } > image :data

  .got :
  {
    *(.got)
  } > image :data

  .got.plt :
  {
    *(.got.plt)
  } > image :data

  .ARM.extab :
  {
    *(.ARM.extab* .gnu.linkonce.armextab.*)
  } > image 

  .ARM.exidx :
  {
    __exidx_start = .;
    *(.ARM.exidx* .gnu.linkonce.armextab.*)
    __exidx_end = .;
  } > image 

  .dynsym :
  {
    *(.dynsym*)
  } > image 

  .dynstr :
  {
    *(.dynstr*)
  } > image

  .plt.rel : 
  {
    *(.plt.rel*)
  } > image

  .interp : 
  {
    *(.interp)
  } > image

  .hash :
  {
    *(.hash)
  } > image

  .dynamic : 
  {
    *(.dynamic)
  } > image
}
