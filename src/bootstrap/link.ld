OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

BASE = 0x2000000;

SECTIONS {
  . = BASE;

  .text : {
    *(.text._start) // entrypoint code
    *(.text .text.*)
  } :text

  .rodata : {
    *(.rodata .rodata.*)
  } :rodata

  .stack : {
    *(.stack)
  } :stack

  .data : {
    *(.data .data.*)
  } :data

  .bss : {
    *(.bss .bss.*)
    *(COMMON)
  } :bss

  /DISCARD/ : {
    *(.eh_frame*)
    *(.note .note.*)
  }
}
