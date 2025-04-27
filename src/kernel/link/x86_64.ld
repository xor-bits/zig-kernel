OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

PHDRS {
  text PT_LOAD;
  rodata PT_LOAD;
  data PT_LOAD;
  bss PT_LOAD;
}

KERNEL_BASE = 0xffffffff80000000;

SECTIONS {
  . = KERNEL_BASE;

  .text : {
    *(.text .text.*)
  } :text

  . = ALIGN(CONSTANT(MAXPAGESIZE));

  .rodata : {
    *(.rodata .rodata.*)
  } :rodata

  . = ALIGN(CONSTANT(MAXPAGESIZE));

  .data : {
    *(.data .data.*)

    // limine stuff
    KEEP(*(.requests_start_marker))
    KEEP(*(.requests))
    KEEP(*(.requests_end_marker))
  } :data

  . = ALIGN(CONSTANT(MAXPAGESIZE));

  .bss : {
    *(.bss .bss.*)
    *(COMMON)
  } :bss

  /DISCARD/ : {
    /* *(.eh_frame*) */
    *(.note .note.*)
  }
}
