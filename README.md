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


