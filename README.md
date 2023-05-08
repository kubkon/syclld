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

### 1.1 compiling the input

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

### 1.2 parsing a relocatable object file

The first thing we'll focus on is parsing relocatable object files. Navigate to `src/Object.zig` and find
`Object.parse`.  This function is responsible for parsing the object's ELF header, input section table, 
input symbol and string tables, as well as converting input sections and input symbols into `Atom` and 
`Symbol` respectively. We use those proxy structures to simplify complex relationship between input 
sections, local and global symbols, garbage collection of unused sections, etc.

In particular, we will focus on implementing two functions that are called within `Object.parse`: `Object.initAtoms` and `Object.initSymtab`.

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
files. Also, since globals are by definition unique to the entire linking process, we store them in the linker-global list `Elf.globals`, and we create an additional by-name index `Elf.globals_table` so that we can refer
to each global by-index and by-name. The former will be used exclusively after symbol resolution is done, while
the latter during symbol resolution.

In order to create a new global `Symbol` instance, we can use `Elf.getOrCreateGlobal`. In order to populate a
global `Symbol` we can use `Object.setGlobal`.

## Part 1

In the first part of the workshop, we will learn how to parse input relocatable object files.
For each object file, we will create a set of input atoms (per each input section), and a set of 
input symbols (according to the object's symbol table).

Objectives:
* understand the format of the ELF file
* understand the concept of a section header (`shdr`)
* understand the concept of a symbol table
* parse section headers into atoms
* parse input symbol table into lists of locals and globals

## Part 2

Now that we know how to parse object files, it is time to resolve the globals into a unique
set of symbols. Normally, they can either be defined in an input relocatable object file,
shared object, or defined by the linker (the so-called synthetic symbols). In our case, since
we do not link against any shared objects, globals have to either be defined in an input
relocatable object file or by the linker iself.

Objectives:
* understand the concept of symbol binding (linkage): local, weak and global
* understand the concept of symbol duplicates and how to handle this
* learn about some synthetic symbols that need to be generated by the linker such as `_DYNAMIC`
* implement the symbol resolver for symbols defined in the relocatable object files
* implement logic responsible for detecting symbol duplicates

## Part 3

Some relocations as generated by the compiler will require the existence of an indirection via a pointer in a
global offset table (GOT). In this part of the workshop, we will learn how to scan the relocations for each
parsed section and create such pointers.

Objectives:
* understand the concept of a relocation type: `R_X86_64_64`, `R_x86_64_GOTPCREL`, etc.
* scan reloctions in each parsed input section and create a GOT pointer for each encountered relocation that
  requires it

## Part 4

Initialize output sections, sort them and initialize required segments.
Create program headers combining multiple matching sections into a single segment sharing the same permission
attributes.

Objectives:
* understand section precedence and its implications on the number of loadable segments

## Part 5

By this point, we have the information necessary to allocate symbols in each output section relative to the 
start address of that section, and its size. In other words, we do not create the final allocation in virtual
memory yet, but instead work out partial offsets that are to be correctly aligned within the output section.

Objectives:
* understand the concept of alignment in memory
* understand that GOT is a special, synthetic section and doesn't need to get symbols allocated
* build a list of all symbols in each output section correctly allocated wrt to the start of the said section

## Part 6

Allocate loadable segments in virtual memory and then allocate output sections, atoms, and symbols.
allocate output sections in virtual memory. 

Objectives:
* understand the concept of memory permission in a loadable (`alloc`) segment
* build a list of program headers, section headers, and output sections fully allocated in virtual memory

## Part 7

For each output section, resolve relocations and commit to a file.

Objectives:
* understand the format of a relocation type (`Elf64_Rela`)
* understand how to correctly resolve each relocation type
* write the resolved chunks to the output file at the correct file offsets

## Part 8

Commit string tables, header, program and section headers to a file.

Objectives:
* create a valid ELF header
* commit program and section headers in appropriate locations within the file

