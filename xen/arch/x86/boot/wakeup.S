        .code16

#define wakesym(sym) (sym - wakeup_start)

        .align 16
ENTRY(wakeup_start)
        cli
        cld

        # setup data segment
        movw    %cs, %ax
        movw    %ax, %ds
        movw    %ax, %ss        # A stack required for BIOS call
        movw    $wakesym(early_stack), %sp

        pushl   $0              # Kill dangerous flag early
        popfl

        # check magic number
        movl    wakesym(real_magic), %eax
        cmpl    $0x12345678, %eax
        jne     bogus_real_magic

        # for acpi_sleep=s3_bios
        testl   $1, wakesym(video_flags)
        jz      1f
        lcall   $0xc000, $3
        movw    %cs, %ax        # In case messed by BIOS
        movw    %ax, %ds
        movw    %ax, %ss        # Need this? How to ret if clobbered?

1:      # for acpi_sleep=s3_mode
        testl   $2, wakesym(video_flags)
        jz      1f
        movl    wakesym(video_mode), %eax
        call    mode_setw

1:      # Show some progress if VGA is resumed
        movw    $0xb800, %ax
        movw    %ax, %fs
        movw    $0x0e00 + 'L', %fs:(0x10)

        # boot trampoline is under 1M, and shift its start into
        # %fs to reference symbols in that area
        movl    $BOOT_TRAMPOLINE, %eax
        shrl    $4, %eax
        movl    %eax, %fs
        lidt    %fs:bootsym(idt_48)
        lgdt    %fs:bootsym(gdt_48)

        movw    $1, %ax
        lmsw    %ax             # Turn on CR0.PE 
        ljmpl   $BOOT_CS32, $bootsym_phys(wakeup_32)

/* This code uses an extended set of video mode numbers. These include:
 * Aliases for standard modes
 *      NORMAL_VGA (-1)
 *      EXTENDED_VGA (-2)
 *      ASK_VGA (-3)
 * Video modes numbered by menu position -- NOT RECOMMENDED because of lack
 * of compatibility when extending the table. These are between 0x00 and 0xff.
 */
#define VIDEO_FIRST_MENU 0x0000

/* Standard BIOS video modes (BIOS number + 0x0100) */
#define VIDEO_FIRST_BIOS 0x0100

/* VESA BIOS video modes (VESA number + 0x0200) */
#define VIDEO_FIRST_VESA 0x0200

/* Video7 special modes (BIOS number + 0x0900) */
#define VIDEO_FIRST_V7 0x0900

# Setting of user mode (AX=mode ID) => CF=success
mode_setw:
        movw    %ax, %bx
        cmpb    $VIDEO_FIRST_VESA>>8, %ah
        jnc     check_vesaw
        decb    %ah

setbadw: clc
        ret

check_vesaw:
        subb    $VIDEO_FIRST_VESA>>8, %bh
        orw     $0x4000, %bx                    # Use linear frame buffer
        movw    $0x4f02, %ax                    # VESA BIOS mode set call
        int     $0x10
        cmpw    $0x004f, %ax                    # AL=4f if implemented
        jnz     _setbadw                        # AH=0 if OK

        stc
        ret

_setbadw: jmp    setbadw

bogus_real_magic:
        movw    $0x0e00 + 'B', %fs:(0x12)
        jmp     bogus_real_magic

        .align 4
real_magic:     .long 0x12345678
         .globl video_mode, video_flags
video_mode:     .long 0
video_flags:    .long 0

        .code32

        # Now in protect mode, with paging disabled
        # Add offset for any reference to xen specific symbols

wakeup_32:
        /* Set up segment registers and initial stack for protected mode */
        mov     $BOOT_DS, %eax
        mov     %eax, %ds
        mov     %eax, %ss
        mov     $bootsym_phys(early_stack), %esp

        # check saved magic again
        mov     $sym_phys(saved_magic), %eax
        add     bootsym_phys(trampoline_xen_phys_start), %eax
        mov     (%eax), %eax
        cmp     $0x9abcdef0, %eax
        jne     bogus_saved_magic
        
        /* fpu init? */

        /* Initialise CR4. */
        mov     $X86_CR4_PAE, %ecx
        mov     %ecx, %cr4

        /* Load pagetable base register */
        mov     $sym_phys(idle_pg_table),%eax
        add     bootsym_phys(trampoline_xen_phys_start),%eax
        mov     %eax,%cr3

        /* Will cpuid feature change after resume? */
        /* Set up EFER (Extended Feature Enable Register). */
        mov     bootsym_phys(cpuid_ext_features),%edi
        test    $0x20100800,%edi /* SYSCALL/SYSRET, No Execute, Long Mode? */
        jz      .Lskip_eferw
        movl    $MSR_EFER,%ecx
        rdmsr
#if CONFIG_PAGING_LEVELS == 4
        btsl    $_EFER_LME,%eax /* Long Mode      */
        btsl    $_EFER_SCE,%eax /* SYSCALL/SYSRET */
#endif
        btl     $20,%edi        /* No Execute?    */
        jnc     1f
        btsl    $_EFER_NX,%eax  /* No Execute     */
1:      wrmsr
.Lskip_eferw:

        wbinvd

        /* Enable paging and flush prefetch queue */
        mov     $0x80050033,%eax /* hi-to-lo: PG,AM,WP,NE,ET,MP,PE */
        mov     %eax,%cr0
        jmp     1f
1:

#if defined(__x86_64__)

        /* Now in compatibility mode. Long-jump to 64-bit mode */
        ljmp    $BOOT_CS64, $bootsym_phys(wakeup_64)

        .code64
wakeup_64:
        /* Jump to high mappings and the higher-level wakeup code. */
        movq    ret_point(%rip), %rbx
        jmp     *%rbx

ret_point:
        .quad   __ret_point

#else /* !defined(__x86_64__) */

        lgdt    gdt_descr
        mov     $(__HYPERVISOR_DS), %eax
        mov     %eax, %ds

        ljmp    $(__HYPERVISOR_CS), $__ret_point

#endif

bogus_saved_magic:
        movw    $0x0e00 + 'S', 0xb8014
        jmp     bogus_saved_magic
