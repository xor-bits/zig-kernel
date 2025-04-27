OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

BASE = 0x2000000;

SECTIONS {
  . = BASE;

  .text : {
    *(.text._start) // entrypoint code
    *(.text .text.*)
  } :text

  .data : {
    . = ALIGN(16);
    . += 0x8000;
    PROVIDE(__stack_end = .);
    *(.data .data.*)
  } :data

  .bss : {
    *(.bss .bss.*)
    *(COMMON)
  } :bss

  .rodata : {
    *(.rodata .rodata.*)
  } :rodata

  /DISCARD/ : {
    *(.eh_frame*)
    *(.note .note.*)
  }
}
