#!/usr/bin/perl
# Decode Thumb-2 BL/BLX and MOVW in a vaddr window of a 32-bit Mach-O slice,
# resolving branch targets to imported stub names. Useful for working out which
# system APIs a stripped guest binary actually calls when a game fails inside
# code we have no source for.
#
#   thumb_calls.pl <binary> <slice_file_offset> <lo_vaddr> <hi_vaddr>
#
# The slice offset comes from the fat header (0 for a thin binary); vaddrs are
# hex. Example — how Zenonia 3's MC_knlGetResource was identified:
#   thumb_calls.pl zenonia3 0x242000 0xD7380 0xD7600
use strict;
use warnings;

my ($file, $slice_base, $lo, $hi) = @ARGV;
$slice_base = hex($slice_base);
$lo = hex($lo);
$hi = hex($hi);

open(my $fh, '<:raw', $file) or die "open: $!";
my $data = do { local $/; <$fh> };
close $fh;
sub u32 { unpack('V', substr($data, $_[0], 4)) }
sub u16 { unpack('v', substr($data, $_[0], 2)) }

my $ncmds = u32($slice_base + 16);
my $p = $slice_base + 28;
my (%sect, $symoff, $nsyms, $stroff, $indirectsymoff);
for my $i (0 .. $ncmds - 1) {
    my ($cmd, $cmdsize) = (u32($p), u32($p + 4));
    if ($cmd == 0x1) {
        my $nsects = u32($p + 48);
        my $sp = $p + 56;
        for my $s (0 .. $nsects - 1) {
            my $sn = unpack('Z16', substr($data, $sp, 16));
            my $sg = unpack('Z16', substr($data, $sp + 16, 16));
            $sect{"$sg,$sn"} = {
                addr => u32($sp + 32), size => u32($sp + 36), off => u32($sp + 40),
                res1 => u32($sp + 60), res2 => u32($sp + 64),
            };
            $sp += 68;
        }
    } elsif ($cmd == 0x2) {           # LC_SYMTAB
        ($symoff, $nsyms, $stroff) = (u32($p + 8), u32($p + 12), u32($p + 16));
    } elsif ($cmd == 0xb) {           # LC_DYSYMTAB
        $indirectsymoff = u32($p + 56);
    }
    $p += $cmdsize;
}

sub symname {
    my $idx = shift;
    my $strx = u32($slice_base + $symoff + $idx * 12);
    return unpack('Z*', substr($data, $slice_base + $stroff + $strx, 128));
}

# stub address -> imported symbol name
my %stub;
for my $sn ('__TEXT,__symbol_stub4', '__TEXT,__symbolstub1', '__TEXT,__picsymbolstub4') {
    my $s = $sect{$sn} or next;
    my $ssize = $s->{res2} || 12;
    my $n = int($s->{size} / $ssize);
    for my $i (0 .. $n - 1) {
        my $isym = u32($slice_base + $indirectsymoff + ($s->{res1} + $i) * 4);
        next if $isym & 0xc0000000;
        $stub{ $s->{addr} + $i * $ssize } = symname($isym);
    }
}
printf("resolved %d stubs\n", scalar keys %stub);

my $text = $sect{'__TEXT,__text'};
sub off { my $v = shift; $slice_base + $text->{off} + ($v - $text->{addr}) }

my $v = $lo;
while ($v < $hi) {
    my $hw1 = u16(off($v));
    my $is32 = (($hw1 & 0xf800) == 0xf800 || ($hw1 & 0xf800) == 0xf000 || ($hw1 & 0xf800) == 0xe800);
    if ($is32) {
        my $hw2 = u16(off($v + 2));
        if (($hw1 & 0xf800) == 0xf000 && ($hw2 & 0xd000) == 0xd000) {    # BL
            my $s = ($hw1 >> 10) & 1;
            my $imm10 = $hw1 & 0x3ff;
            my $j1 = ($hw2 >> 13) & 1;
            my $j2 = ($hw2 >> 11) & 1;
            my $imm11 = $hw2 & 0x7ff;
            my $i1 = 1 - ($j1 ^ $s);
            my $i2 = 1 - ($j2 ^ $s);
            my $imm = ($s << 24) | ($i1 << 23) | ($i2 << 22) | ($imm10 << 12) | ($imm11 << 1);
            $imm -= (1 << 25) if $s;
            my $t = $v + 4 + $imm;
            printf("  %#08x  bl    %#08x  %s\n", $v, $t, $stub{$t} // '');
        } elsif (($hw1 & 0xf800) == 0xf000 && ($hw2 & 0xd001) == 0xc000) { # BLX
            my $s = ($hw1 >> 10) & 1;
            my $imm10h = $hw1 & 0x3ff;
            my $j1 = ($hw2 >> 13) & 1;
            my $j2 = ($hw2 >> 11) & 1;
            my $imm10l = ($hw2 >> 1) & 0x3ff;
            my $i1 = 1 - ($j1 ^ $s);
            my $i2 = 1 - ($j2 ^ $s);
            my $imm = ($s << 24) | ($i1 << 23) | ($i2 << 22) | ($imm10h << 12) | ($imm10l << 2);
            $imm -= (1 << 25) if $s;
            my $t = (($v + 4) & ~3) + $imm;
            printf("  %#08x  blx   %#08x  %s\n", $v, $t, $stub{$t} // '');
        } elsif (($hw1 & 0xfbf0) == 0xf240) {                              # MOVW
            my $imm4 = $hw1 & 0xf;
            my $i = ($hw1 >> 10) & 1;
            my $imm3 = ($hw2 >> 12) & 7;
            my $rd = ($hw2 >> 8) & 0xf;
            my $imm8 = $hw2 & 0xff;
            my $val = ($imm4 << 12) | ($i << 11) | ($imm3 << 8) | $imm8;
            printf("  %#08x  movw  r%-2d #%d (%#x)\n", $v, $rd, $val, $val);
        }
        $v += 4;
    } else {
        if (($hw1 & 0xff00) == 0xb500) { printf("  %#08x  push  {...,lr}\n", $v); }
        elsif (($hw1 & 0xff00) == 0xbd00) { printf("  %#08x  pop   {...,pc}\n", $v); }
        $v += 2;
    }
}
