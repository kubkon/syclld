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

### Part 5 - calculating output section sizes, max alignment, and relative Atom offsets

We are finally getting to something more interesting! Now that we have correctly created output sections we can start
thinking about allocating them in file and in memory. But this problem is best handled in a couple of stages. The
first stage we will focus on is actually adding each `Atom` to the right output section's linked-list of `Atom`'s -
have a look at the fields of `Section` structure. Simultaneously we will add its size (with padding if required) 
bumping section's total size, and also adjust section's max alignment which will always equal alignment of the 
`Atom` with largest alignment. When we add an `Atom` to the section and calculate any padding and bump up section's 
size, we can also calculate each `Atom`'s relative offset with respect to the start of the section assuming that each 
section starts at offset of `0`. This way, when we get to allocating the section in file and in memory, we will only 
need to add the section's absolute offset/memory to each `Atom`'s precomputed offset in this step.

Navigate to `Elf.calcSectionSizes` function. This is where we will want to do it all. The logic for this function should
perform something as follows. For each `Atom`, we pull `Atom`'s assigned output `Section` and append it to the linked-list.
Simultaneously, we work out `Atom`'s relative offset within the section based on its current size and `Atom`'s alignment.

```
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
sect(1) : .text : @0 (0) : align(10) : size(16)
sect(2) : .debug_abbrev : @0 (0) : align(1) : size(27)
sect(3) : .debug_info : @0 (0) : align(1) : size(40)
sect(4) : .debug_str : @0 (0) : align(1) : size(93)
sect(5) : .debug_line : @0 (0) : align(1) : size(42)
sect(6) : .symtab : @0 (0) : align(8) : size(0)
sect(7) : .shstrtab : @0 (0) : align(1) : size(53)
sect(8) : .strtab : @0 (0) : align(1) : size(1)

Output segments
phdr(0) : __R : @40 (200040) : align(8) : filesz(a8) : memsz(a8)
phdr(1) : __R : @0 (0) : align(1000) : filesz(0) : memsz(0)
phdr(2) : X_R : @0 (0) : align(1000) : filesz(0) : memsz(0)


debug(elf): writing atoms in '.text' section
debug(elf): writing ATOM(%1,'.text') at offset 0x0
debug(elf): writing atoms in '.debug_abbrev' section
debug(elf): writing ATOM(%2,'.debug_abbrev') at offset 0x0
debug(elf): writing atoms in '.debug_info' section
debug(elf): writing ATOM(%3,'.debug_info') at offset 0x0
debug(elf): writing atoms in '.debug_str' section
debug(elf): writing ATOM(%4,'.debug_str') at offset 0x0
debug(elf): writing atoms in '.debug_line' section
debug(elf): writing ATOM(%5,'.debug_line') at offset 0x0
debug(elf): writing program headers from 0x40 to 0xe8
debug(elf): writing '.symtab' contents from 0x0 to 0x0
debug(elf): writing '.strtab' contents from 0x0 to 0x1
debug(elf): writing '.shstrtab' contents from 0x0 to 0x53
debug(elf): writing section headers from 0x0 to 0x240
debug(elf): writing ELF header elf.Elf64_Ehdr{ .e_ident = { 127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .e_type = elf.ET.EXEC, .e_machine = elf.EM.X86_64, .e_version = 1, .e_entry = 0, .e_phoff = 64, .e_shoff = 0, .e_flags = 0, .e_ehsize = 64, .e_phentsize = 56, .e_phnum = 3, .e_shentsize = 64, .e_shnum = 0, .e_shstrndx = 0 } at 0x0
error: unhandled relocation type: R_X86_64_32
error: unhandled relocation type: R_X86_64_32
error: unhandled relocation type: R_X86_64_32
error: unhandled relocation type: R_X86_64_32
error: unhandled relocation type: R_X86_64_32
error: unhandled relocation type: R_X86_64_64
error: unhandled relocation type: R_X86_64_64
error: unhandled relocation type: R_X86_64_32
error: unhandled relocation type: R_X86_64_64
```

Yooo, check it out! We have progressed enough to cause errors in the linker to do with missing relocation handling!
This is excellent, however, we definitely do not want to focus on it just yet! Now that we have calculated section
sizes, we want to carry on with allocating sections, segments and atoms in memory!

As a prep for the next step, we will do something rather naughty. Namely, we will completely ignore relocation
handling. It's not the first time we've done something like this and so far this has worked out fine for us.
Navigate to `Atom.resolveRelocs` and change `elf_file.fatal` to `elf_file.warn` to reminds us that we still need
to cover this very crucial bit.

### Part 6 - allocating segments, sections, and atoms

We are now in position to allocate segments, sections, and atoms. First, we will
allocate segments. Navigate to `Elf.allocateSegments`. The trick about segments is that the sections each
segment encompasses should share the same memory permissions. For instance, `.rodata` which is read-only should
be contained within a read-only segment. `.text` on the other hand which is executable but not writable should
be contained within a read-exec segment. A naive approach would be to create a segment per section but this will
be pretty wasteful as each loadable is at least page size aligned which for `x86_64` is 4KB. Therefore, before
allocating segments we sort sections in such a way so that they are contiguous in memory *and* share permissions.
The sorting of sections has already been done for us and you can inspect it in `Elf.sortSections`.

Because sections are sorted, our allocation algorithm should iterate over the segments, get contained sections
for each segment (you can use `Elf.getSectionIndexes` to do just that), and calculate each segment's size, file and memory alignment, and offsets. While working on this we need to bear in mind one thing that the first
loadable segment which necessarily will be read-only has to encompass in its range the ELF header `Elf64_Ehdr` and table of program headers (or the `PT_PHDR` program header as these are equivalent).

```
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
sect(1) : .text : @0 (0) : align(10) : size(16)
sect(2) : .debug_abbrev : @0 (0) : align(1) : size(27)
sect(3) : .debug_info : @0 (0) : align(1) : size(40)
sect(4) : .debug_str : @0 (0) : align(1) : size(93)
sect(5) : .debug_line : @0 (0) : align(1) : size(42)
sect(6) : .symtab : @0 (0) : align(8) : size(0)
sect(7) : .shstrtab : @0 (0) : align(1) : size(53)
sect(8) : .strtab : @0 (0) : align(1) : size(1)

Output segments
phdr(0) : __R : @40 (200040) : align(8) : filesz(a8) : memsz(a8)
phdr(1) : __R : @0 (200000) : align(1000) : filesz(e8) : memsz(e8)
phdr(2) : X_R : @f0 (2010f0) : align(1000) : filesz(16) : memsz(16)


debug(elf): writing atoms in '.text' section
debug(elf): writing ATOM(%1,'.text') at offset 0x0
debug(elf): writing atoms in '.debug_abbrev' section
debug(elf): writing ATOM(%2,'.debug_abbrev') at offset 0x0
debug(elf): writing atoms in '.debug_info' section
debug(elf): writing ATOM(%3,'.debug_info') at offset 0x0
debug(elf): writing atoms in '.debug_str' section
debug(elf): writing ATOM(%4,'.debug_str') at offset 0x0
debug(elf): writing atoms in '.debug_line' section
debug(elf): writing ATOM(%5,'.debug_line') at offset 0x0
debug(elf): writing program headers from 0x40 to 0xe8
debug(elf): writing '.symtab' contents from 0x0 to 0x0
debug(elf): writing '.strtab' contents from 0x0 to 0x1
debug(elf): writing '.shstrtab' contents from 0x0 to 0x53
debug(elf): writing section headers from 0x0 to 0x240
debug(elf): writing ELF header elf.Elf64_Ehdr{ .e_ident = { 127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .e_type = elf.ET.EXEC, .e_machine = elf.EM.X86_64, .e_version = 1, .e_entry = 0, .e_phoff = 64, .e_shoff = 0, .e_flags = 0, .e_ehsize = 64, .e_phentsize = 56, .e_phnum = 3, .e_shentsize = 64, .e_shnum = 0, .e_shstrndx = 0 } at 0x0
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_64
warning: unhandled relocation type: R_X86_64_64
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_64
```

As you can see in the logs, we have allocated the output segments. Next up, allocating sections. Navigate to `Elf.allocateAllocSections`. We need to remember not to touch non-alloc sections as they are handled separately since they don't need to be loaded into memory. Given that we have the segments already laid out in file and
memory, we can iterate each segment, get all sections contained within and set their file and memory offsets.
Once we are done with this, don't forget to uncomment code in `Elf.allocateNonAllocSections`.

If we now try to run the linker, we should see a panic due to integer overflow:

```
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
sect(1) : .text : @f0 (2010f0) : align(10) : size(16)
sect(2) : .debug_abbrev : @106 (0) : align(1) : size(27)
sect(3) : .debug_info : @12d (0) : align(1) : size(40)
sect(4) : .debug_str : @16d (0) : align(1) : size(93)
sect(5) : .debug_line : @200 (0) : align(1) : size(42)
sect(6) : .symtab : @248 (0) : align(8) : size(0)
sect(7) : .shstrtab : @248 (0) : align(1) : size(53)
sect(8) : .strtab : @29b (0) : align(1) : size(1)

Output segments
phdr(0) : __R : @40 (200040) : align(8) : filesz(a8) : memsz(a8)
phdr(1) : __R : @0 (200000) : align(1000) : filesz(e8) : memsz(e8)
phdr(2) : X_R : @f0 (2010f0) : align(1000) : filesz(16) : memsz(16)


debug(elf): writing atoms in '.text' section
thread 94123 panic: integer overflow
/home/kubkon/dev/syclld/src/Elf.zig:903:36: 0x2446de in writeAtoms (syclld)
            const off = atom.value - shdr.sh_addr;
                                   ^
/home/kubkon/dev/syclld/src/Elf.zig:299:24: 0x247090 in flush (syclld)
    try self.writeAtoms();
                       ^
/home/kubkon/dev/syclld/src/main.zig:136:18: 0x24a5b5 in main (syclld)
    try elf.flush();
                 ^
/home/kubkon/opt/lib/zig/std/start.zig:609:37: 0x21d96e in posixCallMainAndExit (syclld)
            const result = root.main() catch |err| {
                                    ^
/home/kubkon/opt/lib/zig/std/start.zig:368:5: 0x21d3d1 in _start (syclld)
    @call(.never_inline, posixCallMainAndExit, .{});
    ^
fish: Job 1, '../../syclld/zig-out/bin/syclld…' terminated by signal SIGABRT (Abort)
```

OK, this is easy to fix! We simply need to allocate `Atom`s next! Navigate to `Elf.allocateAtoms`. This bit should be very straightforward to implement. For each `Atom` we simply get the output section and add its
allocated address to each `Atom`'s `value` field. This is enough as we have already calculated each `Atom`'s
relative offset with respect to start of the containing output section, and we are guaranteed that the final
address of each `Atom` will be properly aligned as each section is aligned to the `Atom` with the largest
alignment.

Re-running the linker on the input generates logs:

```
debug(elf): parsing input file path '/home/kubkon/dev/zld/examples/empty.o'
debug(state): file(0) : /home/kubkon/dev/zld/examples/empty.o
  atoms
    atom(1) : .text : @2010f0 : sect(1) : align(4) : size(16)
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
sect(1) : .text : @f0 (2010f0) : align(10) : size(16)
sect(2) : .debug_abbrev : @106 (0) : align(1) : size(27)
sect(3) : .debug_info : @12d (0) : align(1) : size(40)
sect(4) : .debug_str : @16d (0) : align(1) : size(93)
sect(5) : .debug_line : @200 (0) : align(1) : size(42)
sect(6) : .symtab : @248 (0) : align(8) : size(0)
sect(7) : .shstrtab : @248 (0) : align(1) : size(53)
sect(8) : .strtab : @29b (0) : align(1) : size(1)

Output segments
phdr(0) : __R : @40 (200040) : align(8) : filesz(a8) : memsz(a8)
phdr(1) : __R : @0 (200000) : align(1000) : filesz(e8) : memsz(e8)
phdr(2) : X_R : @f0 (2010f0) : align(1000) : filesz(16) : memsz(16)


debug(elf): writing atoms in '.text' section
debug(elf): writing ATOM(%1,'.text') at offset 0xf0
debug(elf): writing atoms in '.debug_abbrev' section
debug(elf): writing ATOM(%2,'.debug_abbrev') at offset 0x106
debug(elf): writing atoms in '.debug_info' section
debug(elf): writing ATOM(%3,'.debug_info') at offset 0x12d
debug(elf): writing atoms in '.debug_str' section
debug(elf): writing ATOM(%4,'.debug_str') at offset 0x16d
debug(elf): writing atoms in '.debug_line' section
debug(elf): writing ATOM(%5,'.debug_line') at offset 0x200
debug(elf): writing program headers from 0x40 to 0xe8
debug(elf): writing '.symtab' contents from 0x248 to 0x248
debug(elf): writing '.strtab' contents from 0x29b to 0x29c
debug(elf): writing '.shstrtab' contents from 0x248 to 0x29b
debug(elf): writing section headers from 0x0 to 0x240
debug(elf): writing ELF header elf.Elf64_Ehdr{ .e_ident = { 127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .e_type = elf.ET.EXEC, .e_machine = elf.EM.X86_64, .e_version = 1, .e_entry = 0, .e_phoff = 64, .e_shoff = 0, .e_flags = 0, .e_ehsize = 64, .e_phentsize = 56, .e_phnum = 3, .e_shentsize = 64, .e_shnum = 0, .e_shstrndx = 0 } at 0x0
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_64
warning: unhandled relocation type: R_X86_64_64
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_64
```

Note how segments, sections and atoms are now allocated in the logs. Let's now inspect the output file with
`zelf`:

```
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
  Number of program headers:         3
  Size of section headers:           64 (bytes)
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

Entry point 0x0
There are 3 program headers, starting at offset 64

Program Headers:
  Type             Offset           VirtAddr         PhysAddr        
                   FileSiz          MemSiz           Flags  Align
  DYNAMIC          0000000000000006 00000000002010f0 00000000000000f0
                   0000000000000016 0000000000000000 E      000010
  NULL             0000000100000008 0000000000000000 0000000000000000
                   0000000000000106 0000000000000027        000000
  LOAD             0000000000000000 0000000100000016 0000000000000000
                   0000000000000000 000000000000012d        000040

 Section to Segment mapping:
  Segment Sections...
   00     
   01     
   02     

There is no relocation info in this file.

There is no symbol table in this file.
```

This output looks familiar! It seems that we are overwriting the program headers with some bogus data. Firstly,
let's fix writing the header as we are still not setting the number of section headers properly, and that
we have allocated them, we are in position to do that. Next, we also need to set `Elf.shoff` to a correct
value. If you recall, section header table goes at the end of the file, so we can calculate this value by
taking the last section's offset and its size, and aligning the value to `Elf64_Shdr`.

Let's rerun the linker again, and let's reinspect the binary with `zelf`:

```
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
  Start of section headers:          672 (bytes into file)
  Flags:                             0x0
  Size of this header:               64 (bytes)
  Size of program headers:           56 (bytes)
  Number of program headers:         3
  Size of section headers:           64 (bytes)
  Number of section headers:         9
  Section header string table index: 0

There are 9 section headers, starting at offset 0x2a0:

Section Headers:
  [Nr]  Name              Type              Address           Offset
        Size              EntSize           Flags  Link  Info  Align
  [ 0]  <no-strings>      NULL              0000000000000000  0000000000000000
        0000000000000000  0000000000000000            0     0     0
  [ 1]  <no-strings>      PROGBITS          00000000002010f0  00000000000000f0
        0000000000000016  0000000000000000  AX        0     0    16
  [ 2]  <no-strings>      PROGBITS          0000000000000000  0000000000000106
        0000000000000027  0000000000000000            0     0     1
  [ 3]  <no-strings>      PROGBITS          0000000000000000  000000000000012d
        0000000000000040  0000000000000000            0     0     1
  [ 4]  <no-strings>      PROGBITS          0000000000000000  000000000000016d
        0000000000000093  0000000000000000  MS        0     0     1
  [ 5]  <no-strings>      PROGBITS          0000000000000000  0000000000000200
        0000000000000042  0000000000000000            0     0     1
  [ 6]  <no-strings>      SYMTAB            0000000000000000  0000000000000248
        0000000000000000  0000000000000018            8     0     8
  [ 7]  <no-strings>      STRTAB            0000000000000000  0000000000000248
        0000000000000053  0000000000000001            0     0     1
  [ 8]  <no-strings>      STRTAB            0000000000000000  000000000000029b
        0000000000000001  0000000000000001            0     0     1
Key to Flags:
  W (write), A (alloc), X (execute), M (merge), S (strings), I (info),
  L (link order), O (extra OS processing required), G (group), T (TLS),
  C (compressed), x (unknown), o (OS specific), E (exclude),
  D (mbind), l (large), p (processor specific)

Entry point 0x0
There are 3 program headers, starting at offset 64

Program Headers:
  Type             Offset           VirtAddr         PhysAddr        
                   FileSiz          MemSiz           Flags  Align
  PHDR             0000000000000040 0000000000200040 0000000000200040
                   00000000000000a8 00000000000000a8 R      000008
  LOAD             0000000000000000 0000000000200000 0000000000200000
                   00000000000000e8 00000000000000e8 R      001000
  LOAD             00000000000000f0 00000000002010f0 00000000002010f0
                   0000000000000016 0000000000000016 RE     001000

 Section to Segment mapping:
  Segment Sections...
   00     
   01     
   02     <no-strings>

There is no relocation info in this file.

Symbol table '<no-strings>' contains 0 entries:
  Num:            Value  Size Type    Bind   Vis      Ndx   Name
```

This looks almost good if not for the fact we forgot to set the index to `.shstrtab` string table which
contains names of the section headers! Let's fix it up in `Elf.writeHeader`. Now, let's rerun and reinspect
the binary with `zelf`:

```
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
  Start of section headers:          672 (bytes into file)
  Flags:                             0x0
  Size of this header:               64 (bytes)
  Size of program headers:           56 (bytes)
  Number of program headers:         3
  Size of section headers:           64 (bytes)
  Number of section headers:         9
  Section header string table index: 7

There are 9 section headers, starting at offset 0x2a0:

Section Headers:
  [Nr]  Name              Type              Address           Offset
        Size              EntSize           Flags  Link  Info  Align
  [ 0]                    NULL              0000000000000000  0000000000000000
        0000000000000000  0000000000000000            0     0     0
  [ 1]  .text             PROGBITS          00000000002010f0  00000000000000f0
        0000000000000016  0000000000000000  AX        0     0    16
  [ 2]  .debug_abbrev     PROGBITS          0000000000000000  0000000000000106
        0000000000000027  0000000000000000            0     0     1
  [ 3]  .debug_info       PROGBITS          0000000000000000  000000000000012d
        0000000000000040  0000000000000000            0     0     1
  [ 4]  .debug_str        PROGBITS          0000000000000000  000000000000016d
        0000000000000093  0000000000000000  MS        0     0     1
  [ 5]  .debug_line       PROGBITS          0000000000000000  0000000000000200
        0000000000000042  0000000000000000            0     0     1
  [ 6]  .symtab           SYMTAB            0000000000000000  0000000000000248
        0000000000000000  0000000000000018            8     0     8
  [ 7]  .shstrtab         STRTAB            0000000000000000  0000000000000248
        0000000000000053  0000000000000001            0     0     1
  [ 8]  .strtab           STRTAB            0000000000000000  000000000000029b
        0000000000000001  0000000000000001            0     0     1
Key to Flags:
  W (write), A (alloc), X (execute), M (merge), S (strings), I (info),
  L (link order), O (extra OS processing required), G (group), T (TLS),
  C (compressed), x (unknown), o (OS specific), E (exclude),
  D (mbind), l (large), p (processor specific)

Entry point 0x0
There are 3 program headers, starting at offset 64

Program Headers:
  Type             Offset           VirtAddr         PhysAddr        
                   FileSiz          MemSiz           Flags  Align
  PHDR             0000000000000040 0000000000200040 0000000000200040
                   00000000000000a8 00000000000000a8 R      000008
  LOAD             0000000000000000 0000000000200000 0000000000200000
                   00000000000000e8 00000000000000e8 R      001000
  LOAD             00000000000000f0 00000000002010f0 00000000002010f0
                   0000000000000016 0000000000000016 RE     001000

 Section to Segment mapping:
  Segment Sections...
   00     
   01     
   02     .text

There is no relocation info in this file.

Symbol table '.symtab' contains 0 entries:
  Num:            Value  Size Type    Bind   Vis      Ndx   Name
```

Now look at this marvel! If we try running the binary however...

```
$ ./a.out
fish: Job 1, './a.out' terminated by signal SIGSEGV (Address boundary error)
```

Ahhh, it's time to allocate symbols and set the entrypoint address!

### Part 7 - allocating symbols

If you recall, when we were parsing input relocatable object files, we unpacked two tightly related entities: input
sections into `Atom`s, and input symbols into `Symbol`s. You would think that we should allocate `Symbol`s somewhat
earlier, perhaps with `Atom`s or even output sections. Well, it turns out this is not required, as each `Symbol` has
an index into defining `Atom`. Therefore, allocating `Symbol`s should be straightforward and should amount to adding
`Atom`'s `value` to the `Symbol`'s value. Navigate to `Elf.allocateLocals` and let's implement this idea.

If the `Atom` doesn't exist, e.g., for `ST_ABS` symbols, what do you think we should do? In this case, we are safe to
skip allocating the `Symbol`. Next up is `Elf.allocateGlobals`. For globals, there is no need to iterate over
input object files as all globals are conveniently located in linker's global scope. Having said that if we were
toying with the idea of parallelising the linker similarly to how `mold` does it, we would then make allocating
globals via each input object file work in a separate thread.

OK! That should be it! Let's rerun the linker.

```
debug(elf): parsing input file path '/home/kubkon/dev/zld/examples/empty.o'
debug(state): file(0) : /home/kubkon/dev/zld/examples/empty.o
  atoms
    atom(1) : .text : @2010f0 : sect(1) : align(4) : size(16)
    atom(2) : .debug_abbrev : @0 : sect(2) : align(0) : size(27)
    atom(3) : .debug_info : @0 : sect(3) : align(0) : size(40)
    atom(4) : .debug_str : @0 : sect(4) : align(0) : size(93)
    atom(5) : .debug_line : @0 : sect(5) : align(0) : size(42)
  locals
    %0 :  : @0 : undefined
    %1 : empty.c : @0 : absolute : file(0)
    %2 : .text : @2010f0 : sect(1) : atom(1) : file(0)
    %3 : .debug_abbrev : @0 : sect(2) : atom(2) : file(0)
    %4 : .debug_info : @0 : sect(3) : atom(3) : file(0)
    %5 : .eh_frame : @0 : absolute : file(0)
    %6 : .debug_line : @0 : sect(5) : atom(5) : file(0)
    %7 : .llvm_addrsig : @0 : absolute : file(0)
    %8 : .debug_str : @0 : sect(4) : atom(4) : file(0)
    %9 : .comment : @0 : absolute : file(0)
  globals
    %10 : _start : @2010f0 : sect(1) : atom(1) : file(0)

linker-defined
  globals
    %0 : _DYNAMIC : @0 : absolute : synthetic
    %1 : __init_array_start : @2010f0 : sect(1) : synthetic
    %2 : __init_array_end : @2010f0 : sect(1) : synthetic
    %3 : __fini_array_start : @2010f0 : sect(1) : synthetic
    %4 : __fini_array_end : @2010f0 : sect(1) : synthetic
    %5 : _GLOBAL_OFFSET_TABLE_ : @0 : absolute : synthetic

GOT
got_section:

Output sections
sect(0) :  : @0 (0) : align(0) : size(0)
sect(1) : .text : @f0 (2010f0) : align(10) : size(16)
sect(2) : .debug_abbrev : @106 (0) : align(1) : size(27)
sect(3) : .debug_info : @12d (0) : align(1) : size(40)
sect(4) : .debug_str : @16d (0) : align(1) : size(93)
sect(5) : .debug_line : @200 (0) : align(1) : size(42)
sect(6) : .symtab : @248 (0) : align(8) : size(0)
sect(7) : .shstrtab : @248 (0) : align(1) : size(53)
sect(8) : .strtab : @29b (0) : align(1) : size(1)

Output segments
phdr(0) : __R : @40 (200040) : align(8) : filesz(a8) : memsz(a8)
phdr(1) : __R : @0 (200000) : align(1000) : filesz(e8) : memsz(e8)
phdr(2) : X_R : @f0 (2010f0) : align(1000) : filesz(16) : memsz(16)


debug(elf): writing atoms in '.text' section
debug(elf): writing ATOM(%1,'.text') at offset 0xf0
debug(elf): writing atoms in '.debug_abbrev' section
debug(elf): writing ATOM(%2,'.debug_abbrev') at offset 0x106
debug(elf): writing atoms in '.debug_info' section
debug(elf): writing ATOM(%3,'.debug_info') at offset 0x12d
debug(elf): writing atoms in '.debug_str' section
debug(elf): writing ATOM(%4,'.debug_str') at offset 0x16d
debug(elf): writing atoms in '.debug_line' section
debug(elf): writing ATOM(%5,'.debug_line') at offset 0x200
debug(elf): writing program headers from 0x40 to 0xe8
debug(elf): writing '.symtab' contents from 0x248 to 0x248
debug(elf): writing '.strtab' contents from 0x29b to 0x29c
debug(elf): writing '.shstrtab' contents from 0x248 to 0x29b
debug(elf): writing section headers from 0x2a0 to 0x4e0
debug(elf): writing ELF header elf.Elf64_Ehdr{ .e_ident = { 127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, .e_type = elf.ET.EXEC, .e_machine = elf.EM.X86_64, .e_version = 1, .e_entry = 2101488, .e_phoff = 64, .e_shoff = 672, .e_flags = 0, .e_ehsize = 64, .e_phentsize = 56, .e_phnum = 3, .e_shentsize = 64, .e_shnum = 9, .e_shstrndx = 7 } at 0x0
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_64
warning: unhandled relocation type: R_X86_64_64
warning: unhandled relocation type: R_X86_64_32
warning: unhandled relocation type: R_X86_64_64
```

This is looking good! What if try running the binary in its current form?

```
$ ./a.out
```

Well, I'll be damned! It seems to have worked! Let's print the exit status to confirm:

```
$ echo $status
0
```

Wow! It worked even though we still haven't filled in all the blanks yet! This is something that is crucial to remember
that when developing your linker (or any piece of system software) it pays off to work in small albeit verifiable steps!

### Part 8 - setting the symtab

This is all good and well, but if we run `zelf` on the binary we still have a missing bit to fill in, namely the
symbol table!

```
Symbol table '.symtab' contains 0 entries:
  Num:            Value  Size Type    Bind   Vis      Ndx   Name
```

Navigate to `Elf.setSymtab`. This should be a walk in the park by now. All we need to do here is traverse each
input object file, and decide which local symbols we want to add to the output symbol table. Afterwards, we will
traverse the set of globals and do the same. Don't forget to set `shdr.sh_info` to the index of the first global
symbol!

Let's re-run the linker and `zelf` on the output:

```
Symbol table '.symtab' contains 2 entries:
  Num:            Value  Size Type    Bind   Vis      Ndx   Name
    0: 0000000000000000     0 FILE    LOCAL  DEFAULT  UND   empty.c
    1: 00000000002010f0     0 FUNC    GLOBAL DEFAULT  1     _start
```

This is looking great! There is a point to this you know. If you remember we have debug info sections that we took
care of before. We also need the symbol table to be able to break at symbol name in the debugger - this will be
our critical tool for more complex linking scenarios.

```
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
Reading symbols from ./a.out...
(gdb) b _start
Breakpoint 1 at 0x2010f4
(gdb) r
Starting program: /home/kubkon/dev/zld/examples/a.out 

Breakpoint 1, 0x00000000002010f4 in _start ()
(gdb) disas
Dump of assembler code for function _start:
   0x00000000002010f0 <+0>:	push   %rbp
   0x00000000002010f1 <+1>:	mov    %rsp,%rbp
=> 0x00000000002010f4 <+4>:	mov    $0x3c,%rax
   0x00000000002010fb <+11>:	mov    $0x0,%rdi
   0x0000000000201102 <+18>:	syscall 
   0x0000000000201104 <+20>:	pop    %rbp
   0x0000000000201105 <+21>:	ret    
End of assembler dump.
(gdb) n
Single stepping until exit from function _start,
which has no line number information.
[Inferior 1 (process 118835) exited normally]
(gdb)
```

Hmm, seems that one more thing is still missing. Ah yes, relocations!

