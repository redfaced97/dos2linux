bits 16
cpu 386
org 100h

KERNEL_BASE         equ 100000h
COMMAND_LINE_OFFSET equ 8000h
HEAP_END_OFFSET     equ 7E00h
SETUP_MIN_SEGMENT   equ 1000h
SETUP_MAX_SEGMENT   equ 9000h
SETUP_ENTRY_OFFSET  equ 20h
SETUP_RESERVE_PARAS equ 2000h
SECTOR_SIZE         equ 512
HEADER_READ_SIZE    equ 2 * SECTOR_SIZE
FILE_BUFFER_SIZE    equ 4096
STACK_SIZE          equ 2048

PSP_TAIL_LENGTH equ 80h
PSP_TAIL_START  equ 81h
MAX_TAIL_LENGTH equ 126
COMMAND_CAPACITY equ 128
INVALID_HANDLE equ 0FFFFh

BOOT_SETUP_SECTS    equ 1F1h
BOOT_SYSSIZE        equ 1F4h
BOOT_VIDEO_MODE     equ 1FAh
BOOT_SIGNATURE      equ 1FEh
BOOT_HEADER_MAGIC   equ 202h
BOOT_VERSION        equ 206h
BOOT_REALMODE_HOOK  equ 208h
BOOT_LOADER_TYPE    equ 210h
BOOT_LOADFLAGS      equ 211h
BOOT_CODE32_START   equ 214h
BOOT_RAMDISK_IMAGE  equ 218h
BOOT_RAMDISK_SIZE   equ 21Ch
BOOT_HEAP_END_PTR   equ 224h
BOOT_CMD_LINE_PTR   equ 228h
BOOT_INITRD_ADDR_MAX equ 22Ch
BOOT_INIT_SIZE      equ 260h

BOOT_SIGNATURE_VALUE        equ 0AA55h
BOOT_HEADER_MAGIC_VALUE     equ 53726448h
BOOT_PROTOCOL_MIN           equ 204h
BOOT_PROTOCOL_INITRD_LIMIT  equ 203h
BOOT_PROTOCOL_INIT_SIZE     equ 20Ah
DEFAULT_SETUP_SECTS         equ 4
LOADER_TYPE_UNKNOWN         equ 0FFh
VIDEO_MODE_CURRENT          equ 0FFFFh
LOADFLAG_LOADED_HIGH        equ 01h
LOADFLAG_QUIET              equ 20h
LOADFLAG_KEEP_SEGMENTS      equ 40h
LOADFLAG_CAN_USE_HEAP       equ 80h

CODE_SELECTOR               equ 08h
DATA_SELECTOR               equ 10h
CR0_PE                      equ 1

start:
    cld
    cli
    mov ax, cs
    mov ss, ax
    mov sp, stack_top
    sti
    mov ds, ax
    mov es, ax
    mov bx, program_end + 15
    shr bx, 4
    mov ah, 4Ah
    int 21h
    jc memory_error

    xor cx, cx
    mov cl, [PSP_TAIL_LENGTH]
    cmp cx, MAX_TAIL_LENGTH
    ja argument_error
    mov si, PSP_TAIL_START
    mov di, argument_buffer
    rep movsb
    xor al, al
    stosb
    mov si, argument_buffer
.parse:
    call read_token
    jc argument_error
    test dx, dx
    jz .parsed
    mov di, opt_kernel
    call strings_equal
    je .kernel
    mov di, opt_initrd
    call strings_equal
    je .initrd
    mov di, opt_append
    call strings_equal
    jne argument_error
    mov bx, command_line_ptr
    jmp .value
.kernel:
    mov bx, kernel_ptr
    jmp .value
.initrd:
    mov bx, initrd_ptr
.value:
    call read_token
    jc argument_error
    test dx, dx
    jz argument_error
    mov [bx], dx
    jmp .parse
.parsed:
    cmp word [kernel_ptr], 0
    je argument_error
    smsw ax
    test ax, CR0_PE
    jnz mode_error

    mov si, msg_start
    call print_string
    mov dx, [kernel_ptr]
    mov ax, 3D00h
    int 21h
    jc io_error
    mov [kernel_handle], ax
    mov bx, ax
    call file_size
    mov [kernel_size], eax
    mov cx, HEADER_READ_SIZE
    mov dx, file_buffer
    call read_exact
    cmp word [file_buffer + BOOT_SIGNATURE], BOOT_SIGNATURE_VALUE
    jne image_error
    cmp dword [file_buffer + BOOT_HEADER_MAGIC], BOOT_HEADER_MAGIC_VALUE
    jne image_error
    cmp word [file_buffer + BOOT_VERSION], BOOT_PROTOCOL_MIN
    jb image_error
    test byte [file_buffer + BOOT_LOADFLAGS], LOADFLAG_LOADED_HIGH
    jz image_error
    movzx ax, byte [file_buffer + BOOT_SETUP_SECTS]
    test ax, ax
    jnz .setup_size
    mov ax, DEFAULT_SETUP_SECTS
.setup_size:
    inc ax
    shl ax, 9
    cmp ax, COMMAND_LINE_OFFSET
    ja image_error
    cmp ax, HEADER_READ_SIZE
    jb image_error
    mov [setup_size], ax
    movzx edx, ax
    mov eax, [kernel_size]
    sub eax, edx
    jbe image_error
    mov [kernel_size], eax
    mov eax, [file_buffer + BOOT_SYSSIZE]
    test eax, eax
    jz image_error
    cmp eax, 0FFFFFFFh
    ja image_error
    shl eax, 4
    cmp [kernel_size], eax
    jb image_error
    mov [kernel_size], eax

    push bx
    mov bx, SETUP_RESERVE_PARAS
    mov ah, 48h
    int 21h
    pop bx
    jc memory_error
    cmp ax, SETUP_MIN_SEGMENT
    jae .boot_address
    mov ax, SETUP_MIN_SEGMENT
.boot_address:
    cmp ax, SETUP_MAX_SEGMENT
    ja memory_error
    mov [setup_segment], ax
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 10000h / 2
    rep stosw
    mov si, file_buffer
    xor di, di
    mov cx, HEADER_READ_SIZE / 2
    rep movsw
    mov cx, [setup_size]
    sub cx, HEADER_READ_SIZE
    jz .setup_done
    push ds
    mov ax, es
    mov ds, ax
    mov dx, HEADER_READ_SIZE
    mov ah, 3Fh
    int 21h
    pop ds
    jc io_error
    cmp ax, cx
    jne image_error
.setup_done:

    cmp word [initrd_ptr], 0
    je .reserve
    push bx
    mov dx, [initrd_ptr]
    mov ax, 3D00h
    int 21h
    jc io_error
    mov [initrd_handle], ax
    mov bx, ax
    call file_size
    mov [initrd_size], eax
    pop bx
.reserve:
    push bx
    mov ax, 4300h
    int 2Fh
    cmp al, 80h
    jne xms_error
    push es
    mov ax, 4310h
    int 2Fh
    mov [xms_entry], bx
    mov [xms_entry+2], es
    pop es
    xor bl, bl
    mov ah, 08h
    call far [xms_entry]
    test ax, ax
    jz memory_error
    movzx eax, ax
    shl eax, 10
    mov [xms_block_size], eax
    shr eax, 10
    mov dx, ax
    mov ah, 09h
    call far [xms_entry]
    cmp ax, 1
    jne memory_error
    mov [xms_handle], dx
    mov ah, 0Ch
    call far [xms_entry]
    cmp ax, 1
    jne memory_error
    mov byte [xms_locked], 1
    movzx eax, dx
    shl eax, 16
    mov ax, bx
    mov [kernel_staging_base], eax
    mov [copy_destination], eax
    add eax, [xms_block_size]
    jc memory_error
    sub eax, [initrd_size]
    jc memory_error
    and eax, 0FFFFF000h
    mov [initrd_base], eax
    mov edx, [kernel_staging_base]
    cmp edx, KERNEL_BASE
    jb memory_error
    add edx, [kernel_size]
    jc memory_error
    cmp edx, eax
    ja memory_error

    mov edx, [kernel_size]
    cmp word [es:BOOT_VERSION], BOOT_PROTOCOL_INIT_SIZE
    jb .workspace
    cmp edx, [es:BOOT_INIT_SIZE]
    jae .workspace
    mov edx, [es:BOOT_INIT_SIZE]
.workspace:
    add edx, KERNEL_BASE
    jc memory_error
    cmp edx, eax
    ja memory_error
    cmp dword [initrd_size], 0
    je .a20
    add eax, [initrd_size]
    dec eax
    cmp word [es:BOOT_VERSION], BOOT_PROTOCOL_INITRD_LIMIT
    jb memory_error
    cmp eax, [es:BOOT_INITRD_ADDR_MAX]
    ja memory_error
.a20:
    mov ah, 05h
    call far [xms_entry]
    cmp ax, 1
    jne xms_error
    mov byte [a20_enabled], 1
    pop bx

    xor eax, eax
    mov ax, cs
    mov [real_jump+2], ax
    shl eax, 4
    mov [program_base], eax
    mov [gdt_code+2], ax
    shr eax, 16
    mov [gdt_code+4], al
    mov [gdt_code+7], ah
    mov eax, [program_base]
    add eax, gdt
    mov [gdt_desc+2], eax

    mov si, msg_kernel
    call print_string
    mov eax, [kernel_size]
    call load_file
    mov ah, 3Eh
    int 21h
    mov word [kernel_handle], INVALID_HANDLE
    mov si, msg_ok
    call print_string
    mov bx, [initrd_handle]
    cmp bx, INVALID_HANDLE
    je .parameters
    mov si, msg_initrd
    call print_string
    mov eax, [initrd_base]
    mov [copy_destination], eax
    mov eax, [initrd_size]
    call load_file
    mov ah, 3Eh
    int 21h
    mov word [initrd_handle], INVALID_HANDLE
    mov si, msg_ok
    call print_string
.parameters:
    mov ax, [setup_segment]
    mov es, ax
    mov byte [es:BOOT_LOADER_TYPE], LOADER_TYPE_UNKNOWN
    and byte [es:BOOT_LOADFLAGS], ~(LOADFLAG_QUIET | LOADFLAG_KEEP_SEGMENTS) & 0FFh
    or byte [es:BOOT_LOADFLAGS], LOADFLAG_CAN_USE_HEAP
    mov word [es:BOOT_HEAP_END_PTR], HEAP_END_OFFSET
    mov word [es:BOOT_VIDEO_MODE], VIDEO_MODE_CURRENT
    mov dword [es:BOOT_REALMODE_HOOK], 0
    mov dword [es:BOOT_CODE32_START], KERNEL_BASE
    mov dword [es:BOOT_RAMDISK_IMAGE], 0
    mov eax, [initrd_size]
    mov [es:BOOT_RAMDISK_SIZE], eax
    test eax, eax
    jz .command_line
    mov eax, [initrd_base]
    mov [es:BOOT_RAMDISK_IMAGE], eax
.command_line:
    mov di, COMMAND_LINE_OFFSET
    mov si, [command_line_ptr]
    test si, si
    jz .empty
.copy_command:
    lodsb
    stosb
    test al, al
    jnz .copy_command
.empty:
    movzx eax, word [setup_segment]
    shl eax, 4
    add eax, COMMAND_LINE_OFFSET
    mov [es:BOOT_CMD_LINE_PTR], eax
    mov si, msg_jump
    call print_string

    cli
    mov esi, [kernel_staging_base]
    mov edi, KERNEL_BASE
    mov ecx, [kernel_size]
    call flat_copy
    mov ax, [setup_segment]
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, COMMAND_LINE_OFFSET
    xor bx, bx
    mov fs, bx
    mov gs, bx
    add ax, SETUP_ENTRY_OFFSET
    push ax
    push word 0
    retf

read_exact:
    mov ah, 3Fh
    int 21h
    jc io_error
    cmp ax, cx
    jne image_error
    ret

file_size:
    xor cx, cx
    xor dx, dx
    mov ax, 4202h
    int 21h
    jc io_error
    movzx eax, ax
    movzx edx, dx
    shl edx, 16
    or eax, edx
    push eax
    xor cx, cx
    xor dx, dx
    mov ax, 4200h
    int 21h
    jc io_error
    pop eax
    ret

load_file:
    mov [bytes_remaining], eax
.loop:
    mov ecx, [bytes_remaining]
    test ecx, ecx
    jz .done
    cmp ecx, FILE_BUFFER_SIZE
    jbe .read
    mov ecx, FILE_BUFFER_SIZE
.read:
    mov dx, file_buffer
    call read_exact
    movzx ecx, ax
    mov esi, [program_base]
    add esi, file_buffer
    mov edi, [copy_destination]
    call flat_copy
    add [copy_destination], ecx
    sub [bytes_remaining], ecx
    jmp .loop
.done:
    ret

flat_copy:
    pushf
    cli
    push ds
    push es
    pushad
    sgdt [old_gdt]
    lgdt [gdt_desc]
    mov eax, cr0
    or eax, CR0_PE
    mov cr0, eax
    jmp CODE_SELECTOR:.protected
.protected:
    mov ax, DATA_SELECTOR
    mov ds, ax
    mov es, ax
    cld
    a32 rep movsb
    mov eax, cr0
    and eax, ~CR0_PE
    mov cr0, eax
    jmp far [cs:real_jump]
.real:
    popad
    pop es
    pop ds
    lgdt [old_gdt]
    popf
    ret

read_token:
.skip:
    cmp byte [si], ' '
    je .advance
    cmp byte [si], 9
    jne .start
.advance:
    inc si
    jmp .skip
.start:
    xor dx, dx
    cmp byte [si], 0
    je .done
    cmp byte [si], '"'
    je .quoted
    mov dx, si
.word:
    cmp byte [si], 0
    je .done
    cmp byte [si], ' '
    je .terminate
    cmp byte [si], 9
    je .terminate
    inc si
    jmp .word
.quoted:
    inc si
    mov dx, si
.quote:
    cmp byte [si], 0
    je .bad
    cmp byte [si], '"'
    je .close
    inc si
    jmp .quote
.close:
    mov byte [si], 0
    inc si
    cmp byte [si], 0
    je .done
    cmp byte [si], ' '
    je .done
    cmp byte [si], 9
    je .done
.bad:
    stc
    ret
.terminate:
    mov byte [si], 0
    inc si
.done:
    clc
    ret

strings_equal:
    push si
    push ax
    mov si, dx
.loop:
    mov al, [si]
    cmp al, [di]
    jne .done
    inc si
    inc di
    test al, al
    jnz .loop
.done:
    pop ax
    pop si
    ret

print_string:
    pushad
    mov dx, si
    xor cx, cx
.count:
    cmp byte [si], 0
    je .write
    inc si
    inc cx
    jmp .count
.write:
    mov bx, 1
    mov ah, 40h
    int 21h
    popad
    ret

argument_error:
    mov si, msg_usage
    jmp fail
io_error:
    mov si, msg_io
    jmp fail
image_error:
    mov si, msg_image
    jmp fail
memory_error:
    mov si, msg_memory
    jmp fail
mode_error:
    mov si, msg_mode
    jmp fail
xms_error:
    mov si, msg_xms
fail:

    mov ax, cs
    mov ds, ax
    mov es, ax
    mov sp, stack_top
    call print_string
    mov bx, [kernel_handle]
    cmp bx, INVALID_HANDLE
    je .initrd
    mov ah, 3Eh
    int 21h
.initrd:
    mov bx, [initrd_handle]
    cmp bx, INVALID_HANDLE
    je .unlock
    mov ah, 3Eh
    int 21h
.unlock:
    cmp byte [xms_locked], 0
    je .free
    mov dx, [xms_handle]
    mov ah, 0Dh
    call far [xms_entry]
.free:
    cmp word [xms_handle], 0
    je .a20
    mov dx, [xms_handle]
    mov ah, 0Ah
    call far [xms_entry]
.a20:
    cmp byte [a20_enabled], 0
    je .exit
    mov ah, 06h
    call far [xms_entry]
.exit:
    mov ax, 4C01h
    int 21h

kernel_ptr dw 0
initrd_ptr dw 0
command_line_ptr dw 0

kernel_handle dw INVALID_HANDLE
initrd_handle dw INVALID_HANDLE

setup_segment dw 0
setup_size dw 0

xms_handle dw 0
xms_locked db 0
a20_enabled db 0
xms_entry dd 0

kernel_size dd 0
kernel_staging_base dd 0

initrd_size dd 0
initrd_base dd 0

xms_block_size dd 0
program_base dd 0
copy_destination dd 0
bytes_remaining dd 0

real_jump dw flat_copy.real, 0

opt_kernel db '--kernel', 0
opt_initrd db '--initrd', 0
opt_append db '--append', 0

msg_usage db 'usage: kexec.com --kernel FILE [--initrd FILE] [--append "params"]', 13, 10, 0
msg_start db 'DOS2Linux executing ...', 13, 10, 0

msg_kernel db 'Loading kernel ... ', 0
msg_initrd db 'Loading initrd ... ', 0

msg_ok db '[ OK ]', 13, 10, 0
msg_jump db 'Jump to kernel ...', 13, 10, 0

msg_io db 'Error: cannot open, read or seek file.', 13, 10, 0
msg_image db 'Error: invalid/truncated bzImage (boot protocol 2.04+ required).', 13, 10, 0
msg_memory db 'Error: insufficient contiguous memory for kernel and initrd.', 13, 10, 0
msg_mode db 'Error: real-mode DOS required; disable EMM386/Windows.', 13, 10, 0
msg_xms db 'Error: HIMEM.SYS/XMS with A20 support is required.', 13, 10, 0

align 8
gdt:
    dq 0
gdt_code:
    dw 0FFFFh, 0
    db 0, 9Ah, 0, 0
    dw 0FFFFh, 0
    db 0, 92h, 0CFh, 0
gdt_end:
gdt_desc dw gdt_end-gdt-1
    dd 0
old_gdt times 6 db 0

section .bss
argument_buffer resb COMMAND_CAPACITY
alignb 4
file_buffer resb FILE_BUFFER_SIZE
stack resb STACK_SIZE
stack_top:
program_end:

