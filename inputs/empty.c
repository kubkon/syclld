void _start() {
  asm volatile ("movq $60, %rax\n\t"
      "movq $0, %rdi\n\t"
      "syscall");
}
