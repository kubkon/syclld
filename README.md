# SYCL 2023 - Linker Workshop

This repo contains the source code and actual instructions for participating in the SYCL 2023
Linker Workshop in Vancouver.

I thought long and hard how to organise the learning material and converged on the idea of starting with
a linker model that only handles the simplest of cases first. This is how I would learn to handle linking
on the target platform - start with something functional for the simplest possible case and build more
functionality from there. And so, for this workshop, we will do the same. We will start very small, and
thanks to the fact that Linux is a very stable kernel, we can write a functional program that invokes `exit`
syscall without any `libc` involved whatsoever. After we get it working for the simplest case, we can start 
working from there to handle some more interesting cases in an incremental and trackable manner.

## Part 0 - prerequisites

We will need the following tools to work through the workshop:

* `git` - OS dependent
* `zig` - [`ziglang.org/download`](https://ziglang.org/download/)
* `zelf` - [TODO]()
* `zig-objdump` - [TODO]()
* `blink` - [TODO]()

If you are developing natively on Linux (or in a VM!), feel free to swap out `zelf` for `readelf`,
`zig-objdump` for `objdump`, and `blink` for `gdb`.

Next, clone this repo:

```
$ git clone https://github.com/kubkon/syclld
```

And verify we can actually build it:

```
$ cd syclld
$ zig build
```

You should not expect any errors at this stage, so if you do please shout out!

## Part 1 - let's get the ball rolling!

In the first part of the workshop, we will be working towards getting this simple C program to link
correctly:

```c
// simple.c
void _start() {
  asm volatile ("movq $60, %rax\n\t"
      "movq $0, %rdi\n\t"
      "syscall");
}
```

If you know a little bit of `x86_64` assembly, you will quickly recognise that all we do here is
invoke the `exit` syscall with status/error code of `0` meaning `ESUCCESS`. It is also customary on Linux
to denote the entrypoint, i.e., function that will be called first by the kernel or dynamic linker, as `_start`.
This contrived input example is perfect as it will generate the smallest possible relocatable object
file that is easily managed.

### Part 1.1 - compiling the input

Copy-paste the above snippet into `simple.c` source file. Next, fire up your favourite C compiler and
generate an ELF relocatable file:

```
$ zig cc -c simple.c -target x86_64-linux
```

Verify that `simple.o` has indeed been created using `zelf`:

```
$ zelf -h simple.o
ELF Header:
  Magic:   7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00
  Class:                             ELF64
  Data:                              2's complement, little endian
  Version:                           1 (current)
  OS/ABI:                            UNIX - System V
  ABI Version:                       0
  Type:                              REL (Relocatable file)
  Machine:                           Advanced Micro Devices X86-64
  Version:                           0x1
  Entry point address:               0x0
  Start of program headers:          0 (bytes into file)
  Start of section headers:          1280 (bytes into file)
  Flags:                             0x0
  Size of this header:               64 (bytes)
  Size of program headers:           0 (bytes)
  Number of program headers:         0
  Size of section headers:           64 (bytes)
  Number of section headers:         16
  Section header string table index: 14

```

Now go ahead and try to link it with `syclld`:

```
$ zig build run -- simple.o
```

If all goes well, you should see the following error on screen:

```
error: no entrypoint found: '_start'
```

If you browse through the source files of our linker, you will notice a hefty amount of TODOs left in the
code. We will work through them one-by-one until we get no errors reported by the linker and our linker
actually generates *something*. Then, we will work through the bugs until our `simple.c` program links
correctly and runs fine.

As you will notice, the main driving function of the linker is `Elf.flush`. This is where we orchestrate every
next linking stage from.

### Part 1.2 - parsing a relocatable object file

The first thing we'll focus on is parsing relocatable object files. Starting from `Elf.flush`, parsing of objects
is initiated in `Elf.parsePositionals` and next in `Elf.parseObject`. From there we call `Object.parse`.
This function is responsible for parsing the object's ELF header, input section table, 
input symbol and string tables, as well as converting input sections and input symbols into `Atom` and 
`Symbol` respectively. We use those proxy structures to simplify complex relationship between input 
sections, local and global symbols, garbage collection of unused sections, etc.

In particular, we will focus on implementing two functions that are called within `Object.parse`: 
`Object.initAtoms` and `Object.initSymtab`.

#### `Object.initAtoms`

TODO what is an input section? what is an atom?

This function should do the following two things:

1. unpack each input section into an `Atom`, and
2. tie each relocation info section (`SHT_RELA`) to an existing `Atom` created in the previous step.

When unpacking each input section, first we need to decide if we want to keep the section or discard it.
Normally, we would only discard an input section if we had a really good reason to do it such as `SHF_EXCLUDE`
flag, however, since we are building a very basic linker we can build upon, we can freely discard more sections.
Fire up `zelf -S simple.o` and analyse the sections defined in `simple.o`. Sections like `.comment` or 
`.note` are not needed to get the basic program to run, and neither is `SHT_X86_64_UNWIND` or
`SHT_LLVM_ADDRSIG`. For your convenience, there is a function available to you that exclude all of the 
above `Object.skipShdr`.

Having decided which section to skip and which to accept, we need to create an `Atom` and this can be done
via `Elf.addAtom` function. This function returns an index of the newly created `Atom` instance which we can
turn into `*Atom` by calling `Elf.getAtom`.

After we traverse all input sections, we need to re-traverse them one more time and link each visited
relocation info section `SHT_RELA` with a corresponding `Atom` provided it exists.

#### `Object.initSymtab`

Every input symbol table consists of a set of local and global symbols. Local symbols are local to the object
file and as such do not take part in (global) symbol resolution. Following local symbols in the input symbol
table are the so-called global symbols. These symbols are exports, imports (undefined symbols), and they do
take part in (global) symbol resolution that will happen later.

This function should do the following two things:

1. unpack each local symbol tying it to a parsed `Atom` created in `Object.initAtoms`, and
2. unpack each global symbol into a global symbol reference.

To make tracking of symbol names consistent and simpler, we can use `Elf.string_intern` buffer. This will
be very useful for locals of type `STT_SECTION`.

When unpacking globals, it is important to realise that we currently don't care about symbol resolution yet.
For this reason, we will initialise every new global symbol to the first occurrence in any of the input object
files. Also, since globals are by definition unique to the entire linking process, we store them in the linker-global 
list `Elf.globals`, and we create an additional by-name index `Elf.globals_table` so that we can refer
to each global by-index and by-name. The former will be used exclusively after symbol resolution is done, while
the latter during symbol resolution.

In order to create a new global `Symbol` instance, we can use `Elf.getOrCreateGlobal`. In order to populate a
global `Symbol` we can use `Object.setGlobal`.

### Part 1.3 - checkpoint

Now, let's try re-running the linker and see what happens:

```
$ syclld simple.o
```

Oh, no error! What if we try running the generated binary file?

```
$ ./a.out
exec: Failed to execute process: './a.out' the file could not be run by the operating system.
```

OK, progress! We have generated *something* but the OS still doesn't really understand what that is. However, this is
a good starting point to ironing out some common things.

This is a good point to mention that a utility for parsing and pretty printing ELF binaries such as `zelf` or `readelf`
is your best friend at every stage of implementing a linker. Let's fire it up and see what we actually generated:

```
$ zelf -a a.out
ELF Header:
  Magic:   00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
  Class:                             Unknown
  Data:                              2's complement, unknown endian
  Version:                           0 (unknown)
  OS/ABI:                            UNIX - System V
  ABI Version:                       0
  Type:                              NONE (No file type)
  Machine:                           None
  Version:                           0x0
  Entry point address:               0x0
  Start of program headers:          0 (bytes into file)
  Start of section headers:          0 (bytes into file)
  Flags:                             0x0
  Size of this header:               0 (bytes)
  Size of program headers:           0 (bytes)
  Number of program headers:         0
  Size of section headers:           0 (bytes)
  Number of section headers:         0
  Section header string table index: 0

There are 0 section headers, starting at offset 0x0:

Section Headers:
  [Nr]  Name              Type              Address           Offset
        Size              EntSize           Flags  Link  Info  Align
Key to Flags:
  W (write), A (alloc), X (execute), M (merge), S (strings), I (info),
  L (link order), O (extra OS processing required), G (group), T (TLS),
  C (compressed), x (unknown), o (OS specific), E (exclude),
  D (mbind), l (large), p (processor specific)

There are no program headers in this file.

There is no relocation info in this file.

There is no symbol table in this file.
```

Yeah, well, it should be obvious now why the OS refuses to launch the binary - it's empty except for a zero-init
header!

### Part 2 - generating a valid ELF header

I bet you expected we will implement symbol resolution next. We could have, but we got the linker generate an empty
ELF file correctly, so why not switch to fixing the header a little bit and see what happens. In fact, symbol resolution
is currently not very needed as we are linking a single input relocatable object file so we can leave it for later.
Don't you worry though, we will definitely come back to it sooner rather than later.

OK, so let's try and generate a valid, populated ELF header for an executable. What does that look like though?
Meet your next very best friend: `lld` (actually, any working linker will do). We will use another linker to generate
a working executable and compare notes! I should mention here that this comes up a lot during linker writing process.
You implement a feature, see it break horribly, you then fire up something battle-tested and more advanced such as
`lld`, and compare the outputs. Fix differences (or work out why they differ), re-run, rinse and repeat.

Let's create a valid program with `zig` (`zig` bundles `lld` for ELF btw):

```
$ zig cc simple.c -o simple_lld -nostdlib -target x86_64-linux
$ zelf -h simple_lld
ELF Header:
  Magic:   7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00
  Class:                             ELF64
  Data:                              2's complement, little endian
  Version:                           1 (current)
  OS/ABI:                            UNIX - System V
  ABI Version:                       0
  Type:                              EXEC (Executable file)
  Machine:                           Advanced Micro Devices X86-64
  Version:                           0x1
  Entry point address:               0x2011b0
  Start of program headers:          64 (bytes into file)
  Start of section headers:          1104 (bytes into file)
  Flags:                             0x0
  Size of this header:               64 (bytes)
  Size of program headers:           56 (bytes)
  Number of program headers:         5
  Size of section headers:           64 (bytes)
  Number of section headers:         12
  Section header string table index: 10
```

Note that we need to pass `-nostdlib` to `zig cc` so that we don't link against `libc`. We don't need it as we are
calling in to `exit` syscall manually after all, and we define our own `_start` entrypoint, thus no bootstrapping
is needed. (Normally, you defined `main` in your program which is bootstrapped via `libc`'s defined `_start` routine
with command line arguments and environment variables allocated and parsed for us).

While we won't be able to fill in all the details just yet as we haven't worked out how to allocate `Atom`/`Symbol`s 
in memory, or commit them to file, we can at least make sure we programmatically generate a valid ELF header.

Navigate to `Elf.writeHeader` function. This is where we should make adjustments to populate the correct metadata for
our executable ELF file. Feel free to experiment with it, and verify your results with `zelf -h a.out`. Ideally, in
the end, you should see a result similar to:

```
$ zelf -h a.out
ELF Header:
  Magic:   7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00
  Class:                             ELF64
  Data:                              2's complement, little endian
  Version:                           1 (current)
  OS/ABI:                            UNIX - System V
  ABI Version:                       0
  Type:                              EXEC (Executable file)
  Machine:                           Advanced Micro Devices X86-64
  Version:                           0x1
  Entry point address:               0x0
  Start of program headers:          64 (bytes into file)
  Start of section headers:          0 (bytes into file)
  Flags:                             0x0
  Size of this header:               64 (bytes)
  Size of program headers:           56 (bytes)
  Number of program headers:         0
  Size of section headers:           64 (bytes)
  Number of section headers:         0
  Section header string table index: 0
```

In this example, we have purposely hard-coded number of program and section headers to `0`. Let's relax this a little.

### Part 3 - writing program headers

The logic responsible for creating program headers (well, mostly loadable segments) can be found in `Elf.initSegments`.
As you will notice this bit of code was done for us. The logic is fairly simple. It always creater `PT_PHDR` program
header as the first non-loadable segment. This segment is responsible for encapsulating the program header table for
the loader. Next, we always create a loadable read-only segment with the intention that it will encapsulate
the `Elf64_Ehdr` header and the `PT_PHDR` segment.

So far so good. Let's fix the logic in `Elf.writePhdrs` to write the program headers at the correct offset in the file.
Next, let's fixup the number of program headers in the `Elf64_Ehdr` in `Elf.writeHeader`. Note that you can dynamically
get the number of defined program headers by inspecting the length of `Elf.phdrs` arraylist. Once you are done, you
should see something like this when inspecting the generated binary with `zelf`:

```
$ syclld simple.o
$ zelf -h -l a.out
ELF Header:
  Magic:   7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00
  Class:                             ELF64
  Data:                              2's complement, little endian
  Version:                           1 (current)
  OS/ABI:                            UNIX - System V
  ABI Version:                       0
  Type:                              EXEC (Executable file)
  Machine:                           Advanced Micro Devices X86-64
  Version:                           0x1
  Entry point address:               0x0
  Start of program headers:          64 (bytes into file)
  Start of section headers:          0 (bytes into file)
  Flags:                             0x0
  Size of this header:               64 (bytes)
  Size of program headers:           56 (bytes)
  Number of program headers:         2
  Size of section headers:           64 (bytes)
  Number of section headers:         0
  Section header string table index: 0

Entry point 0x0
There are 2 program headers, starting at offset 64

Program Headers:
  Type             Offset           VirtAddr         PhysAddr        
                   FileSiz          MemSiz           Flags  Align
  DYNAMIC          0000000000000000 0000000000000000 0000000000000000
                   0000000000000000 0000000000000000        000000
  NULL             0000000000000008 0000000000000000 0000000000000000
                   0000000000000000 0000000000000000        000000

 Section to Segment mapping:
  Segment Sections...
   00     
   01
```

Do you think this output matches our expected value? If you recall, `Elf.initSegments` should create only two program
headers currently: `PT_PHDR` and `PT_LOAD` with read-only permissions. Instead what we see are two program headers
`PT_DYNAMIC` and `PT_NULL` neither of which we didn't create nor expect to create during this workshop. Clearly, something
is amiss. Let's inspect the logs of the linker while we link this result:

```
$ syclld simple.o --debug-log elf --debug-log state
debug(elf): parsing input file path '/home/kubkon/dev/zld/examples/simple.o'
debug(state): file(0) : /home/kubkon/dev/zld/examples/simple.o
  atoms
    atom(1) : .text : @0 : sect(1) : align(4) : size(16)
    atom(2) : .debug_abbrev : @0 : sect(2) : align(0) : size(27)
    atom(3) : .debug_info : @0 : sect(3) : align(0) : size(40)
    atom(4) : .debug_str : @0 : sect(4) : align(0) : size(93)
    atom(5) : .debug_line : @0 : sect(5) : align(0) : size(42)
  locals
    %0 :  : @0 : undefined
    %1 : empty.c : @0 : absolute : file(0)
    %2 : .text : @0 : absolute : atom(1) : file(0)
    %3 : .debug_abbrev : @0 : absolute : atom(2) : file(0)
    %4 : .debug_info : @0 : absolute : atom(3) : file(0)
    %5 : .eh_frame : @0 : absolute : file(0)
    %6 : .debug_line : @0 : absolute : atom(5) : file(0)
    %7 : .llvm_addrsig : @0 : absolute : file(0)
    %8 : .debug_str : @0 : absolute : atom(4) : file(0)
    %9 : .comment : @0 : absolute : file(0)
  globals
    %10 : _start : @0 : absolute : atom(1) : file(0)

linker-defined
  globals
    %0 : _DYNAMIC : @0 : absolute : synthetic
    %1 : __init_array_start : @0 : sect(1) : synthetic
    %2 : __init_array_end : @0 : sect(1) : synthetic
    %3 : __fini_array_start : @0 : sect(1) : synthetic
    %4 : __fini_array_end : @0 : sect(1) : synthetic
    %5 : _GLOBAL_OFFSET_TABLE_ : @0 : absolute : synthetic

GOT
got_section:

Output sections
sect(0) :  : @0 (0) : align(0) : size(0)
sect(1) : .text : @0 (0) : align(0) : size(0)
sect(2) : .debug_abbrev : @0 (0) : align(0) : size(0)
sect(3) : .debug_info : @0 (0) : align(0) : size(0)
sect(4) : .debug_str : @0 (0) : align(0) : size(0)
sect(5) : .debug_line : @0 (0) : align(0) : size(0)
sect(6) : .symtab : @0 (0) : align(8) : size(0)
sect(7) : .shstrtab : @0 (0) : align(1) : size(53)
sect(8) : .strtab : @53 (0) : align(1) : size(1)

Output segments
phdr(0) : __R : @40 (200040) : align(8) : filesz(70) : memsz(70)
phdr(1) : __R : @0 (0) : align(1000) : filesz(0) : memsz(0)


debug(elf): writing program headers from 0x40 to 0xb0
debug(elf): writing '.symtab' contents from 0x0 to 0x0
debug(elf): writing '.strtab' contents from 0x53 to 0x54
debug(elf): writing '.shstrtab' contents from 0x0 to 0x53
debug(elf): writing section headers from 0x0 to 0x240
debug(elf): writing ELF header elf.Elf64_Ehdr{ .e_ident = { 127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .e_type = elf.ET.EXEC, .e_machine = elf.EM.X86_64, .e_version = 1, .e_entry = 0, .e_phoff = 64, .e_shoff = 0, .e_flags = 0, .e_ehsize = 64, .e_phentsize = 56, .e_phnum = 2, .e_shentsize = 64, .e_shnum = 0, .e_shstrndx = 0 } at 0x0
```

OK, so we have indeed created two program headers, both with read-only permissions, but somehow this is not what ends up
in the produced executable file. Can you spot the bug?

If you look closely towards the end of the log output, you will see that we correctly write out the program headers
table at offset `0x40` (`64` in decimal), however, immediately afterwards we overwrite it with the contents of
`.shstrtab` and the section headers! Inspecting the code further, we can see that we do create some special sections
such as `.symtab`, `.strtab` and `.shstrtab` in `Elf.initSections` function. So we could try and rectify it right here
and now, but then this adds yet another point of potential bugs. Instead, let us comment out the contents of
`Elf.initSections` until we are ready to fix it.

Rebuild and rerun the linker:

```
$ zig build
$ syclld simple.o --debug-log elf --debug-log state
thread 59471 panic: attempt to use null value
/home/kubkon/dev/syclld/src/Elf.zig:798:70: 0x246e69 in setShstrtab (syclld)
    const shdr = &self.sections.items(.shdr)[self.shstrtab_sect_index.?];
                                                                     ^
/home/kubkon/dev/syclld/src/Elf.zig:289:21: 0x24556e in flush (syclld)
    self.setShstrtab();
                    ^
/home/kubkon/dev/syclld/src/main.zig:136:18: 0x247b95 in main (syclld)
    try elf.flush();
                 ^
/home/kubkon/opt/lib/zig/std/start.zig:609:37: 0x21d5ae in posixCallMainAndExit (syclld)
            const result = root.main() catch |err| {
                                    ^
/home/kubkon/opt/lib/zig/std/start.zig:368:5: 0x21d011 in _start (syclld)
    @call(.never_inline, posixCallMainAndExit, .{});
    ^
fish: Job 1, '../../syclld/zig-out/bin/syclld…' terminated by signal SIGABRT (Abort)
```

Oops, we always expect `.shstrtab` to be created. That's fair enough, but for now let's relax this assumption
by checking if we have indeed created the `.shstrtab` section header. Navigate to `Elf.setShstrtab` and check if
`Elf.shstrtab_sect_index != null`. If not, we will exit the function without setting the `.shstrtab` section header.

Rebuild and rerun the linker:

```
$ zig build
$ syclld simple.o --debug-log elf --debug-log state
debug(elf): parsing input file path '/home/kubkon/dev/zld/examples/simple.o'
debug(state): file(0) : /home/kubkon/dev/zld/examples/simple.o
  atoms
    atom(1) : .text : @0 : sect(0) : align(4) : size(16)
    atom(2) : .debug_abbrev : @0 : sect(0) : align(0) : size(27)
    atom(3) : .debug_info : @0 : sect(0) : align(0) : size(40)
    atom(4) : .debug_str : @0 : sect(0) : align(0) : size(93)
    atom(5) : .debug_line : @0 : sect(0) : align(0) : size(42)
  locals
    %0 :  : @0 : undefined
    %1 : empty.c : @0 : absolute : file(0)
    %2 : .text : @0 : absolute : atom(1) : file(0)
    %3 : .debug_abbrev : @0 : absolute : atom(2) : file(0)
    %4 : .debug_info : @0 : absolute : atom(3) : file(0)
    %5 : .eh_frame : @0 : absolute : file(0)
    %6 : .debug_line : @0 : absolute : atom(5) : file(0)
    %7 : .llvm_addrsig : @0 : absolute : file(0)
    %8 : .debug_str : @0 : absolute : atom(4) : file(0)
    %9 : .comment : @0 : absolute : file(0)
  globals
    %10 : _start : @0 : absolute : atom(1) : file(0)

linker-defined
  globals
    %0 : _DYNAMIC : @0 : absolute : synthetic
    %1 : __init_array_start : @0 : absolute : synthetic
    %2 : __init_array_end : @0 : absolute : synthetic
    %3 : __fini_array_start : @0 : absolute : synthetic
    %4 : __fini_array_end : @0 : absolute : synthetic
    %5 : _GLOBAL_OFFSET_TABLE_ : @0 : absolute : synthetic

GOT
got_section:

Output sections
sect(0) :  : @0 (0) : align(0) : size(0)

Output segments
phdr(0) : __R : @40 (200040) : align(8) : filesz(70) : memsz(70)
phdr(1) : __R : @0 (0) : align(1000) : filesz(0) : memsz(0)


debug(elf): writing program headers from 0x40 to 0xb0
thread 59890 panic: attempt to use null value
/home/kubkon/dev/syclld/src/Elf.zig:873:69: 0x243eab in writeShStrtab (syclld)
    const shdr = self.sections.items(.shdr)[self.shstrtab_sect_index.?];
                                                                    ^
/home/kubkon/dev/syclld/src/Elf.zig:304:27: 0x245766 in flush (syclld)
    try self.writeShStrtab();
                          ^
/home/kubkon/dev/syclld/src/main.zig:136:18: 0x247b95 in main (syclld)
    try elf.flush();
                 ^
/home/kubkon/opt/lib/zig/std/start.zig:609:37: 0x21d5ae in posixCallMainAndExit (syclld)
            const result = root.main() catch |err| {
                                    ^
/home/kubkon/opt/lib/zig/std/start.zig:368:5: 0x21d011 in _start (syclld)
    @call(.never_inline, posixCallMainAndExit, .{});
    ^
fish: Job 1, '../../syclld/zig-out/bin/syclld…' terminated by signal SIGABRT (Abort)
```

Ahhh, we missed one spot. We need to check if `Elf.shstrtab_sect_index != null` in `Elf.writeShStrtab` also.
After this change, you should not experience any panics when re-running the linker:

```
$ zig build
$ syclld simple.o --debug-log elf --debug-log state
debug(elf): parsing input file path '/home/kubkon/dev/zld/examples/simple.o'
debug(state): file(0) : /home/kubkon/dev/zld/examples/simple.o
  atoms
    atom(1) : .text : @0 : sect(0) : align(4) : size(16)
    atom(2) : .debug_abbrev : @0 : sect(0) : align(0) : size(27)
    atom(3) : .debug_info : @0 : sect(0) : align(0) : size(40)
    atom(4) : .debug_str : @0 : sect(0) : align(0) : size(93)
    atom(5) : .debug_line : @0 : sect(0) : align(0) : size(42)
  locals
    %0 :  : @0 : undefined
    %1 : empty.c : @0 : absolute : file(0)
    %2 : .text : @0 : absolute : atom(1) : file(0)
    %3 : .debug_abbrev : @0 : absolute : atom(2) : file(0)
    %4 : .debug_info : @0 : absolute : atom(3) : file(0)
    %5 : .eh_frame : @0 : absolute : file(0)
    %6 : .debug_line : @0 : absolute : atom(5) : file(0)
    %7 : .llvm_addrsig : @0 : absolute : file(0)
    %8 : .debug_str : @0 : absolute : atom(4) : file(0)
    %9 : .comment : @0 : absolute : file(0)
  globals
    %10 : _start : @0 : absolute : atom(1) : file(0)

linker-defined
  globals
    %0 : _DYNAMIC : @0 : absolute : synthetic
    %1 : __init_array_start : @0 : absolute : synthetic
    %2 : __init_array_end : @0 : absolute : synthetic
    %3 : __fini_array_start : @0 : absolute : synthetic
    %4 : __fini_array_end : @0 : absolute : synthetic
    %5 : _GLOBAL_OFFSET_TABLE_ : @0 : absolute : synthetic

GOT
got_section:

Output sections
sect(0) :  : @0 (0) : align(0) : size(0)

Output segments
phdr(0) : __R : @40 (200040) : align(8) : filesz(70) : memsz(70)
phdr(1) : __R : @0 (0) : align(1000) : filesz(0) : memsz(0)


debug(elf): writing program headers from 0x40 to 0xb0
debug(elf): writing section headers from 0x0 to 0x40
debug(elf): writing ELF header elf.Elf64_Ehdr{ .e_ident = { 127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .e_type = elf.ET.EXEC, .e_machine = elf.EM.X86_64, .e_version = 1, .e_entry = 0, .e_phoff = 64, .e_shoff = 0, .e_flags = 0, .e_ehsize = 64, .e_phentsize = 56, .e_phnum = 2, .e_shentsize = 64, .e_shnum = 0, .e_shstrndx = 0 } at 0x0
```

Let's re-analyse the produced binary with `zelf`:

```
$ zelf -h -l a.out
ELF Header:
  Magic:   7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00
  Class:                             ELF64
  Data:                              2's complement, little endian
  Version:                           1 (current)
  OS/ABI:                            UNIX - System V
  ABI Version:                       0
  Type:                              EXEC (Executable file)
  Machine:                           Advanced Micro Devices X86-64
  Version:                           0x1
  Entry point address:               0x0
  Start of program headers:          64 (bytes into file)
  Start of section headers:          0 (bytes into file)
  Flags:                             0x0
  Size of this header:               64 (bytes)
  Size of program headers:           56 (bytes)
  Number of program headers:         2
  Size of section headers:           64 (bytes)
  Number of section headers:         0
  Section header string table index: 0

Entry point 0x0
There are 2 program headers, starting at offset 64

Program Headers:
  Type             Offset           VirtAddr         PhysAddr        
                   FileSiz          MemSiz           Flags  Align
  PHDR             0000000000000040 0000000000200040 0000000000200040
                   0000000000000070 0000000000000070 R      000008
  LOAD             0000000000000000 0000000000000000 0000000000000000
                   0000000000000000 0000000000000000 R      001000

 Section to Segment mapping:
  Segment Sections...
   00     
   01
```

Woohoo, success! You can now try running the binary. The error should now change into my personal favourite error
type, the segmentation fault:

```
$ ./a.out
fish: Job 1, './a.out' terminated by signal SIGSEGV (Address boundary error)
$ gdb a.out
GNU gdb (GDB) 12.1
Copyright (C) 2022 Free Software Foundation, Inc.
License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.
Type "show copying" and "show warranty" for details.
This GDB was configured as "x86_64-unknown-linux-gnu".
Type "show configuration" for configuration details.
For bug reporting instructions, please see:
<https://www.gnu.org/software/gdb/bugs/>.
Find the GDB manual and other documentation resources online at:
    <http://www.gnu.org/software/gdb/documentation/>.

For help, type "help".
Type "apropos word" to search for commands related to "word"...
Reading symbols from a.out...
(No debugging symbols found in a.out)
(gdb) r
Starting program: /home/kubkon/dev/zld/examples/a.out 

Program received signal SIGSEGV, Segmentation fault.
0x0000000000000000 in ?? ()
(gdb)
```

Excellent! We can give ourselves a pat on the back - we have made more progress!

### Part 4 - initialising output sections

We could actually keep going trying to write the set of section headers into the file, however, we would be going
against the grain. In ELF, table of section headers directly succeeds the sections - in fact, it is the last thing
in the file. So instead of setting the `Elf.shoff` to some dummy value to make it work, we might as well properly
map each input `Atom` into an output section.

We will start off by uncommenting the code we commented out in Part 3 in `Elf.initSections`. Let's follow along
and navigate to `Atom.initOutputSection` function. As you will notice, this function blindly maps each input section
to an output section of the same name, flags, etc. We don't want to do that as this is wasteful and creates a lot
of chaos in the final executable. Instead, we want to create a mapping such that sections containing executable
machine code are in vast majority mapped to executable and alloc section `.text`. How to work this out? Well, you
guessed it! Let's compare with the output generated by `lld` and try to recreate that in our linker.

```
$ zig cc simple.c -o simple_lld -nostdlib -target x86_64-linux
$ zelf -S simple_lld
There are 12 section headers, starting at offset 0x450:

Section Headers:
  [Nr]  Name              Type              Address           Offset
        Size              EntSize           Flags  Link  Info  Align
  [ 0]                    NULL              0000000000000000  0000000000000000
        0000000000000000  0000000000000000            0     0     0
  [ 1]  .eh_frame_hdr     PROGBITS          0000000000200158  0000000000000158
        0000000000000014  0000000000000000  A         0     0     4
  [ 2]  .eh_frame         PROGBITS          0000000000200170  0000000000000170
        000000000000003c  0000000000000000  A         0     0     8
  [ 3]  .text             PROGBITS          00000000002011b0  00000000000001b0
        0000000000000016  0000000000000000  AX        0     0    16
  [ 4]  .debug_abbrev     PROGBITS          0000000000000000  00000000000001c6
        0000000000000027  0000000000000000            0     0     1
  [ 5]  .debug_info       PROGBITS          0000000000000000  00000000000001ed
        0000000000000040  0000000000000000            0     0     1
  [ 6]  .debug_str        PROGBITS          0000000000000000  000000000000022d
        0000000000000092  0000000000000001  MS        0     0     1
  [ 7]  .comment          PROGBITS          0000000000000000  00000000000002bf
        0000000000000079  0000000000000001  MS        0     0     1
  [ 8]  .debug_line       PROGBITS          0000000000000000  0000000000000338
        0000000000000042  0000000000000000            0     0     1
  [ 9]  .symtab           SYMTAB            0000000000000000  0000000000000380
        0000000000000048  0000000000000018           11     2     8
  [10]  .shstrtab         STRTAB            0000000000000000  00000000000003c8
        0000000000000073  0000000000000000            0     0     1
  [11]  .strtab           STRTAB            0000000000000000  000000000000043b
        0000000000000010  0000000000000000            0     0     1
Key to Flags:
  W (write), A (alloc), X (execute), M (merge), S (strings), I (info),
  L (link order), O (extra OS processing required), G (group), T (TLS),
  C (compressed), x (unknown), o (OS specific), E (exclude),
  D (mbind), l (large), p (processor specific)
```

OK! Firstly, we can safely ignore `.eh_frame` sections as we won't bother with unwind info generation in this
workshop. Similarly. `.comment` section is safe to ignore too. So this leaves us with a `SHT_NULL` section which we
create by default at the start of the `Elf.flush` function, `.text` `SHT_PROGBITS` section that is marked as alloc (A)
and exec (E), debug info sections that either have no flags or are mergable (M) and string (S), and linker-created
sections such as `SHT_SYMTAB` and `SHT_STRTAB`.

Let's try re-running the linker on the input:

```
$ syclld simple.o --debug-log elf --debug-log state
debug(elf): parsing input file path '/home/kubkon/dev/zld/examples/simple.o'
thread 82707 panic: reached unreachable code
/home/kubkon/opt/lib/zig/std/debug.zig:286:14: 0x21f50c in assert (syclld)
    if (!ok) unreachable; // assertion failure
             ^
/home/kubkon/opt/lib/zig/std/mem.zig:3784:31: 0x26abfb in alignForwardGeneric__anon_8615 (syclld)
    assert(isValidAlignGeneric(T, alignment));
                              ^
/home/kubkon/dev/syclld/src/Elf.zig:551:67: 0x247894 in allocateNonAllocSections (syclld)
        shdr.sh_offset = mem.alignForwardGeneric(u64, offset, shdr.sh_addralign);
                                                                  ^
/home/kubkon/dev/syclld/src/Elf.zig:290:34: 0x245e07 in flush (syclld)
    self.allocateNonAllocSections();
                                 ^
/home/kubkon/dev/syclld/src/main.zig:136:18: 0x248415 in main (syclld)
    try elf.flush();
                 ^
/home/kubkon/opt/lib/zig/std/start.zig:609:37: 0x21d5fe in posixCallMainAndExit (syclld)
            const result = root.main() catch |err| {
                                    ^
/home/kubkon/opt/lib/zig/std/start.zig:368:5: 0x21d061 in _start (syclld)
    @call(.never_inline, posixCallMainAndExit, .{});
    ^
fish: Job 1, '../../syclld/zig-out/bin/syclld…' terminated by signal SIGABRT (Abort)
```

Oh oh, something is broken. If you recall `Elf.allocateNonAllocSections` is already implemented for us. Its purpose
is to allocate in file only (non-alloc sections don't get virtual memory allocated) and since we have now implemented
parts of the missing logic in `Atom.initOutputSection`, we are creating debug info sections that are non-alloc and trip
the logic here as we haven't yet populated the output section's max alignment value `shdr.sh_addralign`. We will do
this in the next step. In the meantime, let's comment out the logic in this function and see if this fixes it for us.

```
$ syclld simple.o --debug-log elf --debug-log state
debug(elf): parsing input file path '/home/kubkon/dev/zld/examples/empty.o'
debug(state): file(0) : /home/kubkon/dev/zld/examples/empty.o
  atoms
    atom(1) : .text : @0 : sect(1) : align(4) : size(16)
    atom(2) : .debug_abbrev : @0 : sect(2) : align(0) : size(27)
    atom(3) : .debug_info : @0 : sect(3) : align(0) : size(40)
    atom(4) : .debug_str : @0 : sect(4) : align(0) : size(93)
    atom(5) : .debug_line : @0 : sect(5) : align(0) : size(42)
  locals
    %0 :  : @0 : undefined
    %1 : empty.c : @0 : absolute : file(0)
    %2 : .text : @0 : absolute : atom(1) : file(0)
    %3 : .debug_abbrev : @0 : absolute : atom(2) : file(0)
    %4 : .debug_info : @0 : absolute : atom(3) : file(0)
    %5 : .eh_frame : @0 : absolute : file(0)
    %6 : .debug_line : @0 : absolute : atom(5) : file(0)
    %7 : .llvm_addrsig : @0 : absolute : file(0)
    %8 : .debug_str : @0 : absolute : atom(4) : file(0)
    %9 : .comment : @0 : absolute : file(0)
  globals
    %10 : _start : @0 : absolute : atom(1) : file(0)

linker-defined
  globals
    %0 : _DYNAMIC : @0 : absolute : synthetic
    %1 : __init_array_start : @0 : sect(1) : synthetic
    %2 : __init_array_end : @0 : sect(1) : synthetic
    %3 : __fini_array_start : @0 : sect(1) : synthetic
    %4 : __fini_array_end : @0 : sect(1) : synthetic
    %5 : _GLOBAL_OFFSET_TABLE_ : @0 : absolute : synthetic

GOT
got_section:

Output sections
sect(0) :  : @0 (0) : align(0) : size(0)
sect(1) : .text : @0 (0) : align(0) : size(0)
sect(2) : .debug_abbrev : @0 (0) : align(0) : size(0)
sect(3) : .debug_info : @0 (0) : align(0) : size(0)
sect(4) : .debug_str : @0 (0) : align(0) : size(0)
sect(5) : .debug_line : @0 (0) : align(0) : size(0)
sect(6) : .symtab : @0 (0) : align(8) : size(0)
sect(7) : .shstrtab : @0 (0) : align(1) : size(53)
sect(8) : .strtab : @0 (0) : align(1) : size(1)

Output segments
phdr(0) : __R : @40 (200040) : align(8) : filesz(a8) : memsz(a8)
phdr(1) : __R : @0 (0) : align(1000) : filesz(0) : memsz(0)
phdr(2) : X_R : @0 (0) : align(1000) : filesz(0) : memsz(0)


debug(elf): writing program headers from 0x40 to 0xe8
debug(elf): writing '.symtab' contents from 0x0 to 0x0
debug(elf): writing '.strtab' contents from 0x0 to 0x1
debug(elf): writing '.shstrtab' contents from 0x0 to 0x53
debug(elf): writing section headers from 0x0 to 0x240
debug(elf): writing ELF header elf.Elf64_Ehdr{ .e_ident = { 127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .e_type = elf.ET.EXEC, .e_machine = elf.EM.X86_64, .e_version = 1, .e_entry = 0, .e_phoff = 64, .e_shoff = 0, .e_flags = 0, .e_ehsize = 64, .e_phentsize = 56, .e_phnum = 3, .e_shentsize = 64, .e_shnum = 0, .e_shstrndx = 0 } at 0x0
```

Hah! This is looking good! You can see we have initialised 9 output sections and spawned a new program header with
`X_R` permissions which is exactly what we wanted to do.
