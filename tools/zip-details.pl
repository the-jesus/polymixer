#!/usr/bin/env perl

# zipdetails
#
# Display info on the contents of a Zip file
#

use 5.010; # for unpack "Q<"

my $NESTING_DEBUG = 0 ;

BEGIN {
    # Check for a 32-bit Perl
    if (!eval { pack "Q", 1 }) {
        warn "zipdetails requires 64 bit integers, ",
                "this Perl has 32 bit integers.\n";
        exit(1);
    }
}

BEGIN { pop @INC if $INC[-1] eq '.' }
use strict;
use warnings ;
no  warnings 'portable'; # for unpacking > 2^32
use feature qw(state say);

use IO::File;
use Encode;
use Getopt::Long;
use List::Util qw(min max);

my $VERSION = '4.004' ;

sub fatal_tryWalk;
sub fatal_truncated ;
sub info ;
sub warning ;
sub error ;
sub debug ;
sub fatal ;
sub topLevelFatal ;
sub internalFatal;
sub need ;
sub decimalHex;

use constant MAX64 => 0xFFFFFFFFFFFFFFFF ;
use constant MAX32 => 0xFFFFFFFF ;
use constant MAX16 => 0xFFFF ;

# Compression types
use constant ZIP_CM_STORE                      => 0 ;
use constant ZIP_CM_IMPLODE                    => 6 ;
use constant ZIP_CM_DEFLATE                    => 8 ;
use constant ZIP_CM_BZIP2                      => 12 ;
use constant ZIP_CM_LZMA                       => 14 ;
use constant ZIP_CM_PPMD                       => 98 ;

# General Purpose Flag
use constant ZIP_GP_FLAG_ENCRYPTED_MASK        => (1 << 0) ;
use constant ZIP_GP_FLAG_STREAMING_MASK        => (1 << 3) ;
use constant ZIP_GP_FLAG_PATCHED_MASK          => (1 << 5) ;
use constant ZIP_GP_FLAG_STRONG_ENCRYPTED_MASK => (1 << 6) ;
use constant ZIP_GP_FLAG_LZMA_EOS_PRESENT      => (1 << 1) ;
use constant ZIP_GP_FLAG_LANGUAGE_ENCODING     => (1 << 11) ;
use constant ZIP_GP_FLAG_PKWARE_ENHANCED_COMP  => (1 << 12) ;
use constant ZIP_GP_FLAG_ENCRYPTED_CD          => (1 << 13) ;

# All the encryption flags
use constant ZIP_GP_FLAG_ALL_ENCRYPT            => (ZIP_GP_FLAG_ENCRYPTED_MASK | ZIP_GP_FLAG_STRONG_ENCRYPTED_MASK | ZIP_GP_FLAG_ENCRYPTED_CD );

# Internal File Attributes
use constant ZIP_IFA_TEXT_MASK                 => 1;

# Signatures for each of the headers
use constant ZIP_LOCAL_HDR_SIG                 => 0x04034b50;
use constant ZIP_DATA_HDR_SIG                  => 0x08074b50;
use constant ZIP_CENTRAL_HDR_SIG               => 0x02014b50;
use constant ZIP_END_CENTRAL_HDR_SIG           => 0x06054b50;
use constant ZIP64_END_CENTRAL_REC_HDR_SIG     => 0x06064b50;
use constant ZIP64_END_CENTRAL_LOC_HDR_SIG     => 0x07064b50;
use constant ZIP_DIGITAL_SIGNATURE_SIG         => 0x05054b50;
use constant ZIP_ARCHIVE_EXTRA_DATA_RECORD_SIG => 0x08064b50;
use constant ZIP_SINGLE_SEGMENT_MARKER         => 0x30304b50; # APPNOTE 6.3.10, sec 8.5.4

# Extra sizes
use constant ZIP_EXTRA_HEADER_SIZE          => 2 ;
use constant ZIP_EXTRA_MAX_SIZE             => 0xFFFF ;
use constant ZIP_EXTRA_SUBFIELD_ID_SIZE     => 2 ;
use constant ZIP_EXTRA_SUBFIELD_LEN_SIZE    => 2 ;
use constant ZIP_EXTRA_SUBFIELD_HEADER_SIZE => ZIP_EXTRA_SUBFIELD_ID_SIZE +
                                               ZIP_EXTRA_SUBFIELD_LEN_SIZE;
use constant ZIP_EXTRA_SUBFIELD_MAX_SIZE    => ZIP_EXTRA_MAX_SIZE -
                                               ZIP_EXTRA_SUBFIELD_HEADER_SIZE;

use constant ZIP_EOCD_MIN_SIZE              => 22 ;


use constant ZIP_LD_FILENAME_OFFSET         => 30;
use constant ZIP_CD_FILENAME_OFFSET         => 46;

my %ZIP_CompressionMethods =
    (
          0 => 'Stored',
          1 => 'Shrunk',
          2 => 'Reduced compression factor 1',
          3 => 'Reduced compression factor 2',
          4 => 'Reduced compression factor 3',
          5 => 'Reduced compression factor 4',
          6 => 'Imploded',
          7 => 'Reserved for Tokenizing compression algorithm',
          8 => 'Deflated',
          9 => 'Deflate64',
         10 => 'PKWARE Data Compression Library Imploding',
         11 => 'Reserved by PKWARE',
         12 => 'BZIP2',
         13 => 'Reserved by PKWARE',
         14 => 'LZMA',
         15 => 'Reserved by PKWARE',
         16 => 'IBM z/OS CMPSC Compression',
         17 => 'Reserved by PKWARE',
         18 => 'IBM/TERSE or Xceed BWT', # APPNOTE has IBM/TERSE. Xceed reuses it unofficially
         19 => 'IBM LZ77 z Architecture (PFS)',
         20 => 'Ipaq8', # see https://encode.su/threads/1048-info-zip-lpaq8
         92 => 'Reference', # Winzip Only from version 25
         93 => 'Zstandard',
         94 => 'MP3',
         95 => 'XZ',
         96 => 'WinZip JPEG Compression',
         97 => 'WavPack compressed data',
         98 => 'PPMd version I, Rev 1',
         99 => 'AES Encryption', # Apple also use this code for LZFSE compression in IPA files
     );

my %OS_Lookup = (
    0   => "MS-DOS",
    1   => "Amiga",
    2   => "OpenVMS",
    3   => "Unix",
    4   => "VM/CMS",
    5   => "Atari ST",
    6   => "HPFS (OS/2, NT 3.x)",
    7   => "Macintosh",
    8   => "Z-System",
    9   => "CP/M",
    10  => "Windows NTFS or TOPS-20",
    11  => "MVS or NTFS",
    12  => "VSE or SMS/QDOS",
    13  => "Acorn RISC OS",
    14  => "VFAT",
    15  => "alternate MVS",
    16  => "BeOS",
    17  => "Tandem",
    18  => "OS/400",
    19  => "OS/X (Darwin)",
    30  => "AtheOS/Syllable",
    );

{
    package Signatures ;

    my %Lookup = (
        # Map unpacked signature to
        #   decoder
        #   name
        #   central flag

        # Core Signatures
        ::ZIP_LOCAL_HDR_SIG,             [ \&::LocalHeader, "Local File Header", 0 ],
        ::ZIP_DATA_HDR_SIG,              [ \&::DataDescriptor,   "Data Descriptor", 0 ],
        ::ZIP_CENTRAL_HDR_SIG,           [ \&::CentralHeader, "Central Directory Header", 1 ],
        ::ZIP_END_CENTRAL_HDR_SIG,       [ \&::EndCentralHeader, "End Central Directory Record", 1 ],
        ::ZIP_SINGLE_SEGMENT_MARKER,     [ \&::SingleSegmentMarker, "Split Archive Single Segment Marker", 0],

        # Zip64
        ::ZIP64_END_CENTRAL_REC_HDR_SIG, [ \&::Zip64EndCentralHeader, "Zip64 End of Central Directory Record", 1 ],
        ::ZIP64_END_CENTRAL_LOC_HDR_SIG, [ \&::Zip64EndCentralLocator, "Zip64 End of Central Directory Locator", 1 ],

        #  Digital signature (pkzip)
        ::ZIP_DIGITAL_SIGNATURE_SIG,     [ \&::DigitalSignature, "Digital Signature", 1 ],

        #  Archive Encryption Headers (pkzip) - never seen this one
        ::ZIP_ARCHIVE_EXTRA_DATA_RECORD_SIG,  [ \&::ArchiveExtraDataRecord, "Archive Extra Record", 1 ],
    );

    sub decoder
    {
        my $signature = shift ;

        return undef
            unless exists $Lookup{$signature};

        return $Lookup{$signature}[0];
    }

    sub name
    {
        my $signature = shift ;

        return 'UNKNOWN'
            unless exists $Lookup{$signature};

        return $Lookup{$signature}[1];
    }

    sub titleName
    {
        my $signature = shift ;

        uc name($signature);
    }

    sub hexValue
    {
        my $signature = shift ;
        sprintf "0x%X", $signature ;
    }

    sub hexValue32
    {
        my $signature = shift ;
        sprintf "0x%08X", $signature ;
    }

    sub hexValue16
    {
        my $signature = shift ;
        sprintf "0x%04X", $signature ;
    }

    sub nameAndHex
    {
        my $signature = shift ;

        return "'" . name($signature) . "' (" . hexValue32($signature) . ")"
    }

    sub isCentralHeader
    {
        my $signature = shift ;

        return undef
            unless exists $Lookup{$signature};

        return $Lookup{$signature}[2];
    }
    #sub isValidSignature
    #{
    #    my $signature = shift ;
    #    return exists $Lookup{$signature}}
    #}

    sub getSigsForScan
    {
        my %sigs =
            # map { $_ => 1         }
            # map { substr($_->[0], 2, 2) => $_->[1] } # don't want the initial "PK"
            map { substr(pack("V", $_), 2, 2) => $_           }
            keys %Lookup ;

        return %sigs;
    }

}

my %Extras = (

      #                                                                                                 Local                   Central
      # ID       Name                                                       Handler                     min size    max size    min size max size
      0x0001,  ['ZIP64',                                                    \&decode_Zip64,             0,  28, 0,  28],
      0x0007,  ['AV Info',                                                  undef], # TODO
      0x0008,  ['Extended Language Encoding',                               undef], # TODO
      0x0009,  ['OS/2 extended attributes',                                 undef], # TODO
      0x000a,  ['NTFS FileTimes',                                           \&decode_NTFS_Filetimes,    32, 32, 32, 32],
      0x000c,  ['OpenVMS',                                                  \&decode_OpenVMS,            4, undef,  4, undef],
      0x000d,  ['Unix',                                                     undef],
      0x000e,  ['Stream & Fork Descriptors',                                undef], # TODO
      0x000f,  ['Patch Descriptor',                                         undef],
      0x0014,  ['PKCS#7 Store for X.509 Certificates',                      undef],
      0x0015,  ['X.509 Certificate ID and Signature for individual file',   undef],
      0x0016,  ['X.509 Certificate ID for Central Directory',               undef],
      0x0017,  ['Strong Encryption Header',                                 \&decode_strong_encryption,  12,    undef,  12,    undef],
      0x0018,  ['Record Management Controls',                               undef],
      0x0019,  ['PKCS#7 Encryption Recipient Certificate List',             undef],
      0x0020,  ['Reserved for Timestamp record',                            undef],
      0x0021,  ['Policy Decryption Key Record',                             undef],
      0x0022,  ['Smartcrypt Key Provider Record',                           undef],
      0x0023,  ['Smartcrypt Policy Key Data Record',                        undef],

      # The Header ID mappings defined by Info-ZIP and third parties are:

      0x0065,  ['IBM S/390 attributes - uncompressed',                      \&decode_MVS,                    4,  undef,  4,  undef],
      0x0066,  ['IBM S/390 attributes - compressed',                        undef],
      0x07c8,  ['Info-ZIP Macintosh (old, J. Lee)',                         undef],
      0x10c5,  ['Minizip CMS Signature',                                    \&decode_Minizip_Signature,     undef, undef, undef, undef], # https://github.com/zlib-ng/minizip-ng/blob/master/doc/mz_extrafield.md
      0x1986,  ['Pixar USD',                                                undef], # TODO
      0x1a51,  ['Minizip Hash',                                             \&decode_Minizip_Hash,          4, undef, 4, undef], # https://github.com/zlib-ng/minizip-ng/blob/master/doc/mz_extrafield.md
      0x2605,  ['ZipIt Macintosh (first version)',                          undef],
      0x2705,  ['ZipIt Macintosh v 1.3.5 and newer (w/o full filename)',    undef],
      0x2805,  ['ZipIt Macintosh v 1.3.5 and newer',                        undef],
      0x334d,  ["Info-ZIP Macintosh (new, D. Haase's 'Mac3' field)",        undef], # TODO
      0x4154,  ['Tandem NSK [TA]',                                          undef], # TODO
      0x4341,  ['Acorn/SparkFS [AC]',                                       undef], # TODO
      0x4453,  ['Windows NT security descriptor [SD]',                      \&decode_NT_security,           11, undef,  4, 4], # TODO
      0x4690,  ['POSZIP 4690',                                              undef],
      0x4704,  ['VM/CMS',                                                   undef],
      0x470f,  ['MVS',                                                      undef],
      0x4854,  ['Theos [TH]',                                               undef],
      0x4b46,  ['FWKCS MD5 [FK]',                                           undef],
      0x4c41,  ['OS/2 access control list [AL]',                            undef],
      0x4d49,  ['Info-ZIP OpenVMS (obsolete) [IM]',                         undef],
      0x4d63,  ['Macintosh SmartZIP [cM]',                                  undef], # TODO
      0x4f4c,  ['Xceed original location [LO]',                             undef],
      0x5356,  ['AOS/VS (binary ACL) [VS]',                                 undef],
      0x5455,  ['Extended Timestamp [UT]',                                  \&decode_UT,                    1, 13,  1, 13],
      0x554e,  ['Xceed unicode extra field [UN]',                           \&decode_Xceed_unicode,         6,  undef,  8,  undef],
      0x564B,  ['Key-Value Pairs [KV]',                                     \&decode_Key_Value_Pair,        13, undef, 13, undef],# TODO -- https://github.com/sozip/keyvaluepairs-spec/blob/master/zip_keyvalue_extra_field_specification.md
      0x5855,  ['Unix Extra type 1 [UX]',                                   \&decode_UX,                    12, 12,     8, 8],
      0x5a4c,  ['ZipArchive Unicode Filename [LZ]',                         undef],  # https://www.artpol-software.com/ZipArchive
      0x5a4d,  ['ZipArchive Offsets Array [MZ]',                            undef],  # https://www.artpol-software.com/ZipArchive
      0x6375,  ['Unicode Comment [uc]',                                     \&decode_uc,                    5, undef,  5, undef],
      0x6542,  ['BeOS/Haiku [Be]',                                          undef], # TODO
      0x6854,  ['Theos [Th]',                                               undef],
      0x7075,  ['Unicode Path [up]',                                        \&decode_up,                    5, undef,   5, undef],
      0x756e,  ['ASi Unix [un]',                                            \&decode_ASi_Unix], # TODO
      0x7441,  ['AtheOS [At]',                                              undef],
      0x7855,  ['Unix Extra type 2 [Ux]',                                   \&decode_Ux,                    4,4,   0, 0 ],
      0x7875,  ['Unix Extra type 3 [ux]',                                   \&decode_ux,                    3, undef,   3, undef],
      0x9901,  ['AES Encryption',                                           \&decode_AES,                   7, 7,       7, 7],
      0x9903,  ['Reference',                                                \&decode_Reference,             20, 20,     20, 20], # Added in WinZip ver 25
      0xa11e,  ['Data Stream Alignment',                                    \&decode_DataStreamAlignment,   2, undef,   2, undef ],
      0xA220,  ['Open Packaging Growth Hint',                               \&decode_GrowthHint,            4, undef,   4, undef ],
      0xCAFE,  ['Java Executable',                                          \&decode_Java_exe,              0, 0,       0, 0],
      0xCDCD,  ['Minizip Central Directory',                                \&decode_Minizip_CD,            8, 8, 8, 8], # https://github.com/zlib-ng/minizip-ng/blob/master/doc/mz_extrafield.md
      0xd935,  ['Android APK Alignment',                                    undef], # TODO
      0xE57a,  ['ALZip Codepage',                                           undef], # TODO
      0xfb4a,  ['SMS/QDOS',                                                 undef], # TODO
       );

      # Dummy entry only used in test harness, so only enable when ZIPDETAILS_TESTHARNESS is set
      $Extras{0xFFFF} =
               ['DUMMY',                                                    \&decode_DUMMY,                 undef, undef, undef, undef]
            if $ENV{ZIPDETAILS_TESTHARNESS} ;

sub extraFieldIdentifier
{
    my $id = shift ;

    my $name = $Extras{$id}[0] // "Unknown";

    return "Extra Field '$name' (ID " .  hexValue16($id) .")";
}

# Zip64EndCentralHeader version 2
my %HashIDLookup  = (
        0x0000 => 'none',
        0x0001 => 'CRC32',
        0x8003 => 'MD5',
        0x8004 => 'SHA1',
        0x8007 => 'RIPEMD160',
        0x800C => 'SHA256',
        0x800D => 'SHA384',
        0x800E => 'SHA512',
    );


# Zip64EndCentralHeader version 2, Strong Encryption Header & DecryptionHeader
my %AlgIdLookup = (
        0x6601 => "DES",
        0x6602 => "RC2 (version needed to extract < 5.2)",
        0x6603 => "3DES 168",
        0x6609 => "3DES 112",
        0x660E => "AES 128",
        0x660F => "AES 192",
        0x6610 => "AES 256",
        0x6702 => "RC2 (version needed to extract >= 5.2)",
        0x6720 => "Blowfish",
        0x6721 => "Twofish",
        0x6801 => "RC4",
        0xFFFF => "Unknown algorithm",
    );

# Zip64EndCentralHeader version 2, Strong Encryption Header & DecryptionHeader
my %FlagsLookup = (
        0x0001 => "Password required to decrypt",
        0x0002 => "Certificates only",
        0x0003 => "Password or certificate required to decrypt",

        # Values > 0x0003 reserved for certificate processing
    );

# Strong Encryption Header & DecryptionHeader
my %HashAlgLookup = (
        0x8004  => 'SHA1',
    );

my $FH;

my $ZIP64 = 0 ;
my $NIBBLES = 8;

my $LocalHeaderCount = 0;
my $CentralHeaderCount = 0;
my $InfoCount = 0;
my $WarningCount = 0;
my $ErrorCount = 0;
my $lastWasMessage = 0;

my $fatalDisabled = 0;

my $OFFSET = 0 ;

# Prefix data
my $POSSIBLE_PREFIX_DELTA = 0;
my $PREFIX_DELTA = 0;

my $TRAILING = 0 ;
my $PAYLOADLIMIT = 256;
my $ZERO = 0 ;
my $APK = 0 ;
my $START_APK = 0;
my $APK_LEN = 0;

my $CentralDirectory = CentralDirectory->new();
my $LocalDirectory = LocalDirectory->new();
my $HeaderOffsetIndex = HeaderOffsetIndex->new();
my $EOCD_Present = 0;

sub prOff
{
    my $offset = shift;
    my $s = offset($OFFSET);
    $OFFSET += $offset;
    return $s;
}

sub offset
{
    my $v = shift ;

    sprintf("%0${NIBBLES}X", $v);
}

# Format variables
my ($OFF,  $ENDS_AT, $LENGTH,  $CONTENT, $TEXT, $VALUE) ;

my $FMT1 = 'STDOUT1';
my $FMT2 = 'STDOUT2';

sub setupFormat
{
    my $wantVerbose = shift ;
    my $nibbles = shift;

    my $width = '@' . ('>' x ($nibbles -1));
    my $space = " " x length($width);

    # See https://github.com/Perl/perl5/issues/14255 for issue with "^*" in perl < 5.22
    # my $rightColumn = "^*" ;
    my $rightColumn = "^" . ("<" x 132);

    # Fill mode can split on space or newline chars
    # Spliting on hyphen works differently from Perl 5.20 onwards
    $: = " \n";

    my $fmt ;

    if ($wantVerbose) {

        eval "format $FMT1 =
$width $width $width ^<<<<<<<<<<<^<<<<<<<<<<<<<<<<<<<< $rightColumn
\$OFF,     \$ENDS_AT, \$LENGTH,  \$CONTENT, \$TEXT,    \$VALUE
$space $space $space ^<<<<<<<<<<<^<<<<<<<<<<<<<<<<<<<< $rightColumn~~
                    \$CONTENT, \$TEXT,                 \$VALUE
.
";

        eval "format $FMT2 =
$width $width $width ^<<<<<<<<<<<  ^<<<<<<<<<<<<<<<<<< $rightColumn
\$OFF,     \$ENDS_AT, \$LENGTH,  \$CONTENT, \$TEXT,               \$VALUE
$space $space $space ^<<<<<<<<<<<  ^<<<<<<<<<<<<<<<<<< $rightColumn~~
              \$CONTENT, \$TEXT,               \$VALUE
.
";

    }
    else {
        eval "format $FMT1 =
$width ^<<<<<<<<<<<<<<<<<<<< $rightColumn
\$OFF,      \$TEXT,               \$VALUE
$space ^<<<<<<<<<<<<<<<<<<<< $rightColumn~~
                    \$TEXT,               \$VALUE
.
";

        eval "format $FMT2 =
$width   ^<<<<<<<<<<<<<<<<<< $rightColumn
\$OFF,     \$TEXT,               \$VALUE
$space   ^<<<<<<<<<<<<<<<<<< $rightColumn~~
                    \$TEXT,               \$VALUE
.
"
    }

    no strict 'refs';
    open($FMT1, ">&", \*STDOUT); select $FMT1; $| = 1 ;
    open($FMT2, ">&", \*STDOUT); select $FMT2; $| = 1 ;

    select 'STDOUT';
    $| = 1;

}

sub mySpr
{
    my $format = shift ;

    return "" if ! defined $format;
    return $format unless @_ ;
    return sprintf $format, @_ ;
}

sub xDump
{
    my $input = shift;

    $input =~ tr/\0-\37\177-\377/./;
    return $input;
}

sub hexDump
{
    return uc join ' ', unpack('(H2)*', $_[0]);
}

sub hexDump16
{
    return uc
           join "\r",
           map { join ' ', unpack('(H2)*', $_ ) }
           unpack('(a16)*', $_[0]) ;
}

sub charDump2
{
    sprintf "%v02X", $_[0];
}

sub charDump
{
    sprintf "%vX", $_[0];
}

sub hexValue
{
    return sprintf("0x%X", $_[0]);
}

sub hexValue32
{
    return sprintf("0x%08X", $_[0]);
}

sub hexValue16
{
    return sprintf("0x%04X", $_[0]);
}

sub outHexdump
{
    my $size = shift;
    my $text = shift;
    my $limit = shift ;

    return 0
        if $size == 0;

    # TODO - add a limit to data output
    # if ($limit)
    # {
    #     outSomeData($size, $text);
    # }
    # else
    {
        myRead(my $payload, $size);
        out($payload, $text, hexDump16($payload));
    }

    return $size;
}

sub decimalHex
{
    sprintf("%0*X (%u)", $_[1] // 0, $_[0], $_[0])
}

sub decimalHex0x
{
    sprintf("0x%0*X (%u)", $_[1] // 0, $_[0], $_[0])
}

sub decimalHex0xUndef
{
    return 'Unknown'
        if ! defined $_[0];

    return decimalHex0x @_;
}

sub out
{
    my $data = shift;
    my $text = shift;
    my $format = shift;

    my $size = length($data) ;

    $ENDS_AT = offset($OFFSET + ($size ? $size - 1 : 0)) ;
    $OFF     = prOff($size);
    $LENGTH  = offset($size) ;
    $CONTENT = hexDump($data);
    $TEXT    = $text;
    $VALUE   = mySpr $format,  @_;

    no warnings;

    write $FMT1 ;

    $lastWasMessage = 0;
}

sub out0
{
    my $size = shift;
    my $text = shift;
    my $format = shift;

    $ENDS_AT = offset($OFFSET + ($size ? $size - 1 : 0)) ;
    $OFF     = prOff($size);
    $LENGTH  = offset($size) ;
    $CONTENT = '...';
    $TEXT    = $text;
    $VALUE   = mySpr $format,  @_;

    write $FMT1;

    skip($FH, $size);

    $lastWasMessage = 0;
}

sub out1
{
    my $text = shift;
    my $format = shift;

    $ENDS_AT = '' ;
    $OFF     = '';
    $LENGTH  = '' ;
    $CONTENT = '';
    $TEXT    = $text;
    $VALUE   = mySpr $format,  @_;

    write $FMT1;

    $lastWasMessage = 0;
}

sub out2
{
    my $data = shift ;
    my $text = shift ;
    my $format = shift;

    my $size = length($data) ;
    $ENDS_AT = offset($OFFSET + ($size ? $size - 1 : 0)) ;
    $OFF     = prOff($size);
    $LENGTH  = offset($size);
    $CONTENT = hexDump($data);
    $TEXT    = $text;
    $VALUE   = mySpr $format,  @_;

    no warnings;
    write $FMT2;

    $lastWasMessage = 0;
}


sub Value
{
    my $letter = shift;

    if ($letter eq 'C')
      { return decimalHex($_[0], 2) }
    elsif ($letter eq 'v')
      { return decimalHex($_[0], 4) }
    elsif ($letter eq 'V')
      { return decimalHex($_[0], 8) }
    elsif ($letter eq 'Q<')
      { return decimalHex($_[0], 16) }
    else
      { internalFatal undef, "here letter $letter"}
}

sub outer
{
    my $name = shift ;
    my $unpack = shift ;
    my $size = shift ;
    my $cb1  = shift ;
    my $cb2  = shift ;


    myRead(my $buff, $size);
    my (@value) = unpack $unpack, $buff;
    my $hex = Value($unpack,  @value);

    if (defined $cb1) {
        my $v ;
        if (ref $cb1 eq 'CODE') {
            $v = $cb1->(@value) ;
        }
        else {
            $v = $cb1 ;
        }

        $v = "'" . $v unless $v =~ /^'/;
        $v .= "'"     unless $v =~ /'$/;
        $hex .= " $v" ;
    }

    out $buff, $name, $hex ;

    $cb2->(@value)
        if defined $cb2 ;

    return $value[0];
}

sub out_C
{
    my $name = shift ;
    my $cb1  = shift ;
    my $cb2  = shift ;

    outer($name, 'C', 1, $cb1, $cb2);
}

sub out_v
{
    my $name = shift ;
    my $cb1  = shift ;
    my $cb2  = shift ;

    outer($name, 'v', 2, $cb1, $cb2);
}

sub out_V
{
    my $name = shift ;
    my $cb1  = shift ;
    my $cb2  = shift ;

    outer($name, 'V', 4, $cb1, $cb2);
}

sub out_Q
{
    my $name = shift ;
    my $cb1  = shift ;
    my $cb2  = shift ;

    outer($name, 'Q<', 8, $cb1, $cb2);
}

sub outSomeData
{
    my $size = shift;
    my $message = shift;
    my $redact = shift ;

    # return if $size == 0;

    if ($size > 0) {
        if ($size > $PAYLOADLIMIT) {
            my $before = $FH->tell();
            out0 $size, $message;
        } else {
            myRead(my $buffer, $size );
            $buffer = "X" x $size
                if $redact;
            out $buffer, $message, xDump $buffer ;
        }
    }
}

sub outSomeDataParagraph
{
    my $size = shift;
    my $message = shift;
    my $redact = shift ;

    return if $size == 0;

    print "\n";
    outSomeData($size, $message, $redact);

}

sub unpackValue_C
{
    Value_v(unpack "C", $_[0]);
}

sub Value_C
{
    return decimalHex($_[0], 2);
}


sub unpackValue_v
{
    Value_v(unpack "v", $_[0]);
}

sub Value_v
{
    return decimalHex($_[0], 4);
}

sub unpackValue_V
{
    Value_V(unpack "V", $_[0]);
}

sub Value_V
{
    return decimalHex($_[0] // 0, 8);
}

sub unpackValue_Q
{
    my $v = unpack ("Q<", $_[0]);
    Value_Q($v);
}

sub Value_Q
{
    return decimalHex($_[0], 16);
}

sub read_Q
{
    my $b ;
    myRead($b, 8);
    return ($b, unpack ("Q<" , $b));
}

sub read_V
{
    my $b ;
    myRead($b, 4);
    return ($b, unpack ("V", $b));
}

sub read_v
{
    my $b ;
    myRead($b, 2);
    return ($b, unpack "v", $b);
}


sub read_C
{
    my $b ;
    myRead($b, 1);
    return ($b, unpack "C", $b);
}

sub seekTo
{
    my $offset = shift ;
    my $loc = shift ;

    $loc = SEEK_SET
        if ! defined $loc ;

    $FH->seek($offset, $loc);
    $OFFSET = $FH->tell();
}

sub rewindRelative
{
    my $offset = shift ;

    $FH->seek(-$offset, SEEK_CUR);
    # $OFFSET -= $offset;
    $OFFSET = $FH->tell();
}

sub deltaToNextSignature
{
    my $start = $FH->tell();

    my $got = scanForSignature(1);

    my $delta = $FH->tell() - $start ;
    seekTo($start);

    if ($got)
    {
        return $delta ;
    }

    return 0 ;
}

sub scanForSignature
{
    my $walk = shift // 0;

    # $count is only used to when 'walk' is enabled.
    # Want to scan for a PK header at the start of the file.
    # All other PK headers are should be directly after the previous PK record.
    state $count = 0;
    $count += $walk;

    my %sigs = Signatures::getSigsForScan();

    my $start = $FH->tell();

    # TODO -- Fix this?
    if (1 || $count <= 1) {

        my $last = '';
        my $offset = 0;
        my $buffer ;

        BUFFER:
        while ($FH->read($buffer, 1024 * 1000))
        {
            my $combine = $last . $buffer ;

            my $ix = 0;
            while (1)
            {
                $ix = index($combine, "PK", $ix) ;

                if ($ix == -1)
                {
                    $last = '';
                    next BUFFER;
                }

                my $rest = substr($combine, $ix + 2, 2);

                if (! $sigs{$rest})
                {
                    $ix += 2;
                    next;
                }

                # possible match
                my $here = $FH->tell();
                seekTo($here - length($combine) + $ix);

                my $name = Signatures::name($sigs{$rest});
                return $sigs{$rest};
            }

            $last = substr($combine, $ix+4);
        }
    }
    else {
        die "FIX THIS";
        return ! $FH->eof();
    }

    # printf("scanForSignature %X\t%X (%X)\t%s\n", $start, $FH->tell(), $FH->tell() - $start, 'NO MATCH') ;

    return 0;
}

my $is64In32 = 0;

my $opt_verbose = 0;
my $opt_scan = 0;
my $opt_walk = 0;
my $opt_Redact = 0;
my $opt_utc = 0;
my $opt_want_info_mesages = 1;
my $opt_want_warning_mesages = 1;
my $opt_want_error_mesages = 1;
my $opt_want_message_exit_status = 0;
my $exit_status_code = 0;
my $opt_help =0;

$Getopt::Long::bundling = 1 ;

TextEncoding::setDefaults();

GetOptions("h|help"     => \$opt_help,
           "v"          => \$opt_verbose,
           "scan"       => \$opt_scan,
           "walk"       => \$opt_walk,
           "redact"     => \$opt_Redact,
           "utc"        => \$opt_utc,
           "version"    => sub { print "$VERSION\n"; exit },

           # Filename/comment encoding
           "encoding=s"          => \&TextEncoding::parseEncodingOption,
           "no-encoding"         => \&TextEncoding::NoEncoding,
           "debug-encoding"      => \&TextEncoding::debugEncoding,
           "output-encoding=s"   => \&TextEncoding::parseEncodingOption,
           "language-encoding!"  => \&TextEncoding::LanguageEncodingFlag,

           # Message control
           "exit-bitmask!"      => \$opt_want_message_exit_status,
           "messages!"          => sub {
                                            my ($opt_name, $opt_value) = @_;
                                            $opt_want_info_mesages =
                                            $opt_want_warning_mesages =
                                            $opt_want_error_mesages = $opt_value;
                                       },
    )
  or exit 255 ;

Usage()
    if $opt_help;

die("No zipfile\n")
    unless @ARGV == 1;

die("Cannot specify both '--walk' and '--scan'\n")
    if $opt_walk && $opt_scan ;

my $filename = shift @ARGV;

topLevelFatal "No such file"
    unless -e $filename ;

topLevelFatal "'$filename' is a directory"
    if -d $filename ;

topLevelFatal "'$filename' is not a standard file"
    unless -f $filename ;

$FH = IO::File->new( "<$filename" )
    or topLevelFatal "Cannot open '$filename': $!";
binmode($FH);

displayFileInfo($filename);
TextEncoding::encodingInfo();

my $FILELEN = -s $filename ;
$TRAILING = -s $filename ;
$NIBBLES = nibbles(-s $filename) ;

topLevelFatal "'$filename' is empty"
    if $FILELEN == 0 ;

topLevelFatal "file is too short to be a zip file"
    if $FILELEN <  ZIP_EOCD_MIN_SIZE ;

setupFormat($opt_verbose, $NIBBLES);

my @Messages = ();

if ($opt_scan || $opt_walk)
{
    # Main loop for walk/scan processing

    my $foundZipRecords = 0;
    my $foundCentralHeader = 0;
    my $lastEndsAt = 0;
    my $lastSignature = 0;
    my $lastHeader = {};

    $CentralDirectory->{alreadyScanned} = 1 ;

    my $output_encryptedCD = 0;

    reportPrefixData();
    while(my $s = scanForSignature($opt_walk))
    {
        my $here = $FH->tell();
        my $delta = $here - $lastEndsAt ;

        # delta can only be negative when '--scan' is used
        if ($delta < 0 )
        {
            # nested or overlap
            # check if nested
            # remember & check if matching entry in CD
            # printf("### WARNING: OVERLAP/NESTED Record found 0x%X 0x%X $delta\n", $here, $lastEndsAt) ;
        }
        elsif ($here != $lastEndsAt)
        {
            # scanForSignature had to skip bytes to find the next signature

            # some special cases that don't have signatures need to be checked first

            seekTo($lastEndsAt);

            if (! $output_encryptedCD && $CentralDirectory->isEncryptedCD())
            {
                displayEncryptedCD();
                $output_encryptedCD = 1;
                $lastEndsAt = $FH->tell();
                next;
            }
            elsif ($lastSignature == ZIP_LOCAL_HDR_SIG && $lastHeader->{'streamed'} )
            {
                # Check for size of possibe malformed Data Descriptor before outputting payload
                if (! $lastHeader->{'gotDataDescriptorSize'})
                {
                    my $hdrSize = checkForBadlyFormedDataDescriptor($lastHeader, $delta) ;

                    if ($hdrSize)
                    {
                        # remove size of Data Descriptor from payload
                        $delta -= $hdrSize;
                        $lastHeader->{'gotDataDescriptorSize'} = $hdrSize;
                    }
                }

                if(defined($lastHeader->{'payloadOutput'}) && ($lastEndsAt = BadlyFormedDataDescriptor($lastHeader, $delta)))
                {
                    $HeaderOffsetIndex->rewindIndex();
                    $lastHeader->{entry}->readDataDescriptor(1) ;
                    next;
                }

                # Assume we have the payload when streaming is enabled
                outSomeData($delta, "PAYLOAD", $opt_Redact) ;
                $lastHeader->{'payloadOutput'} = 1;
                $lastEndsAt = $FH->tell();

                next;
            }
            elsif (Signatures::isCentralHeader($s) && $foundCentralHeader == 0)
            {
                # check for an APK header directly before the first central header
                $foundCentralHeader = 1;

                ($START_APK, $APK, $APK_LEN) = chckForAPKSigningBlock($FH, $here, 0) ;

                if ($START_APK)
                {
                    seekTo($lastEndsAt+4);

                    scanApkBlock();
                    $lastEndsAt = $FH->tell();
                    next;
                }

                seekTo($lastEndsAt);
            }

            # Not a special case, so output generic padding message
            if ($delta > 0)
            {
                reportPrefixData($delta)
                    if $lastEndsAt == 0 ;
                outSomeDataParagraph($delta, "UNEXPECTED PADDING");
                info  $FH->tell() - $delta, decimalHex0x($delta) . " Unexpected Padding bytes"
                    if $FH->tell() - $delta ;
                $POSSIBLE_PREFIX_DELTA = $delta
                    if $lastEndsAt ==  0;
                $lastEndsAt = $FH->tell();
                next;
            }
            else
            {
                seekTo($here);
            }

        }

        my ($buffer, $signature) = read_V();

        $lastSignature = $signature;

        my $handler = Signatures::decoder($signature);
        if (!defined $handler) {
            internalFatal undef, "xxx";
        }

        $foundZipRecords = 1;
        $lastHeader = $handler->($signature, $buffer, $FH->tell() - 4) // {'streamed' => 0};

        $lastEndsAt = $FH->tell();

        seekTo($here + 4)
            if $opt_scan;
    }

    topLevelFatal "'$filename' is not a zip file"
        unless $foundZipRecords ;

}
else
{
    # Main loop for non-walk/scan processing

    # check for prefix data
    my $s = scanForSignature();
    if ($s && $FH->tell() != 0)
    {
        $POSSIBLE_PREFIX_DELTA = $FH->tell();
    }

    seekTo(0);

    scanCentralDirectory($FH);

    fatal_tryWalk undef, "No Zip metadata found at end of file"
        if ! $CentralDirectory->exists() && ! $EOCD_Present ;

    $CentralDirectory->{alreadyScanned} = 1 ;

    Nesting::clearStack();

    # $HeaderOffsetIndex->dump();

    $OFFSET = 0 ;
    $FH->seek(0, SEEK_SET) ;

    my $expectedOffset = 0;
    my $expectedSignature = 0;
    my $expectedBuffer = 0;
    my $foundCentralHeader = 0;
    my $processedAPK = 0;
    my $processedECD = 0;
    my $lastHeader ;

    # my $lastWasLocalHeader = 0;
    # my $inCentralHeader = 0;

    while (1)
    {
        last if $FH->eof();

        my $here = $FH->tell();

        if ($here >= $TRAILING) {
            my $delta = $FILELEN - $TRAILING;
            outSomeDataParagraph($delta, "TRAILING DATA");
            info  $FH->tell(), "Unexpected Trailing Data: " . decimalHex0x($delta) . " bytes";

            last;
        }

        my ($buffer, $signature) = read_V();

        $expectedOffset = undef;
        $expectedSignature = undef;

        # Check for split archive marker at start of file
        if ($here == 0 && $signature == ZIP_SINGLE_SEGMENT_MARKER)
        {
            #  let it drop through
            $expectedSignature = ZIP_SINGLE_SEGMENT_MARKER;
            $expectedOffset = 0;
        }
        else
        {
            my $expectedEntry = $HeaderOffsetIndex->getNextIndex() ;
            if ($expectedEntry)
            {
                $expectedOffset = $expectedEntry->offset();
                $expectedSignature = $expectedEntry->signature();
                $expectedBuffer = pack "V", $expectedSignature ;
            }
        }

        my $delta = $expectedOffset - $here ;

        # if ($here != $expectedOffset && $signature != ZIP_DATA_HDR_SIG)
        # {
        #     rewindRelative(4);
        #     my $delta = $expectedOffset - $here ;
        #     outSomeDataParagraph($delta, "UNEXPECTED PADDING");
        #     $HeaderOffsetIndex->rewindIndex();
        #     next;
        # }

        # Need to check for use-case where
        # * there is a ZIP_DATA_HDR_SIG directly after a ZIP_LOCAL_HDR_SIG.
        #   The HeaderOffsetIndex object doesn't have visibility of it.
        # * APK header directly before the CD
        # * zipbomb

        if (defined $expectedOffset && $here != $expectedOffset && ( $CentralDirectory->exists() || $EOCD_Present) )
        {
            if ($here > $expectedOffset)
            {
                # Probable zipbomb

                # Cursor $OFFSET need to rewind
                $OFFSET = $expectedOffset;
                $FH->seek($OFFSET + 4, SEEK_SET) ;

                $signature = $expectedSignature;
                $buffer = $expectedBuffer ;
            }

            # If get here then $here is less than $expectedOffset


            # check for an APK header directly before the first central header
            # Make sure not to miss a streaming data descriptor
            if ($signature != ZIP_DATA_HDR_SIG && Signatures::isCentralHeader($expectedSignature) && $START_APK && ! $processedAPK )
            {
                seekTo($here+4);
                # rewindRelative(4);
                scanApkBlock();
                $HeaderOffsetIndex->rewindIndex();
                $processedAPK = 1;
                next;
            }

            # Check Encrypted Central Directory
            # if ($CentralHeaderSignatures{$expectedSignature} && $CentralDirectory->isEncryptedCD() && ! $processedECD)
            # {
            #     # rewind the invalid signature
            #     seekTo($here);
            #     # rewindRelative(4);
            #     displayEncryptedCD();
            #     $processedECD = 1;
            #     next;
            # }

            if ($signature != ZIP_DATA_HDR_SIG && $delta >= 0)
            {
                rewindRelative(4);
                if($lastHeader->{'streamed'} && BadlyFormedDataDescriptor($lastHeader, $delta))
                {
                    $lastHeader->{entry}->readDataDescriptor(1) ;
                    $HeaderOffsetIndex->rewindIndex();
                    next;
                }

                reportPrefixData($delta)
                    if $here == 0;
                outSomeDataParagraph($delta, "UNEXPECTED PADDING");
                info  $FH->tell() - $delta, decimalHex0x($delta) . " Unexpected Padding bytes"
                    if $FH->tell() - $delta ;
                $HeaderOffsetIndex->rewindIndex();
                next;
            }

            # ZIP_DATA_HDR_SIG drops through
        }

        my $handler = Signatures::decoder($signature);

        if (!defined $handler)
        {
            # if ($CentralDirectory->exists()) {

            #     # Should be at offset that central directory says
            #     my $locOffset = $CentralDirectory->getNextLocalOffset();
            #     my $delta = $locOffset - $here ;

            #     if ($here + 4 == $locOffset ) {
            #         for (0 .. 3) {
            #             $FH->ungetc(ord(substr($buffer, $_, 1)))
            #         }
            #         outSomeData($delta, "UNEXPECTED PADDING");
            #         next;
            #     }
            # }


            # if ($here == $CentralDirectory->{CentralDirectoryOffset} && $EOCD_Present && $CentralDirectory->isEncryptedCD())
            # {
            #     # rewind the invalid signature
            #     rewindRelative(4);
            #     displayEncryptedCD();
            #     next;
            # }
            # elsif ($here < $CentralDirectory->{CentralDirectoryOffset})
            # {
            #     # next
            #     #     if scanForSignature() ;

            #     my $skippedFrom = $FH->tell() ;
            #     my $skippedContent = $CentralDirectory->{CentralDirectoryOffset} - $skippedFrom ;

            #     printf "\nWARNING!\nExpected Zip header not found at offset 0x%X\n", $here;
            #     printf "Skipping 0x%X bytes to Central Directory...\n", $skippedContent;

            #     push @Messages,
            #         sprintf("Expected Zip header not found at offset 0x%X, ", $skippedFrom) .
            #         sprintf("skipped 0x%X bytes\n", $skippedContent);

            #     seekTo($CentralDirectory->{CentralDirectoryOffset});

            #     next;
            # }
            # else
            {
                fatal $here, sprintf "Unexpected Zip Signature '%s' at offset %s", Value_V($signature), decimalHex0x($here) ;
                last;
            }
        }

        $ZIP64 = 0 if $signature != ZIP_DATA_HDR_SIG ;
        $lastHeader = $handler->($signature, $buffer, $FH->tell() - 4);
        # $lastWasLocalHeader = $signature == ZIP_LOCAL_HDR_SIG ;
        $HeaderOffsetIndex->rewindIndex()
            if $signature == ZIP_DATA_HDR_SIG ;
    }
}


dislayMessages()
    if $opt_want_error_mesages ;

exit $exit_status_code ;

sub dislayMessages
{

    # Compare Central & Local for discrepencies

    if ($CentralDirectory->isMiniZipEncrypted)
    {
        # don't compare local & central entries when minizip-ng encryption is in play
        info undef, "Zip file uses minizip-ng central directory encryption"
    }

    elsif ($CentralDirectory->exists() && $LocalDirectory->exists())
    {
        # TODO check number of entries matches eocd
        # TODO check header length matches reality

        # Nesting::dump();

        $LocalDirectory->sortByLocalOffset();
        my %cleanCentralEntries = %{ $CentralDirectory->{byCentralOffset} };

        if ($NESTING_DEBUG)
        {
            if (Nesting::encapsulationCount())
            {
                say "# ENCAPSULATIONS";

                for my $index (sort { $a <=> $b } keys %{ Nesting::encapsulations() })
                {
                    my $outer = Nesting::entryByIndex($index) ;

                    say "# Nesting " . $outer->outputFilename . " " . $outer->offsetStart . " " . $outer->offsetEnd ;

                    for my $inner (sort { $a <=> $b } @{  Nesting::encapsulations()->{$index} } )
                    {
                        say "#  " . $inner->outputFilename . " " . $inner->offsetStart . " " . $inner->offsetEnd ;;
                    }
                }
            }
        }

        {
            # check for Local Directory orphans

           my %orphans = map  {   $_->localHeaderOffset => $_->outputFilename }
                         grep {   $_->entryType == ZIP_LOCAL_HDR_SIG && # Want Local Headers
                                ! $_->encapsulated   &&
                                  @{ $_->getCdEntries } == 0
                           }
                         values %{ Nesting::getEntriesByOffset() };


            if (keys %orphans)
            {
                error undef, "Orphan Local Headers found: " . scalar(keys %orphans) ;

                my $table = new SimpleTable;
                $table->addHeaderRow('Offset', 'Filename');
                $table->addDataRow(decimalHex0x($_), $orphans{$_})
                    for sort { $a <=> $b } keys %orphans ;

                $table->display();
            }
        }

        {
            # check for Central Directory orphans
            # probably only an issue with --walk & a zipbomb

           my %orphans = map  {      $_->centralHeaderOffset => $_         }
                         grep {      $_->entryType == ZIP_CENTRAL_HDR_SIG # Want Central Headers
                                && ! $_->ldEntry                     # Filter out orphans
                                && ! $_->encapsulated                # Not encapsulated
                         }
                         values %{ Nesting::getEntriesByOffset() };

            if (keys %orphans)
            {
                error undef, "Possible zipbomb -- Orphan Central Headers found: " . scalar(keys %orphans) ;

                my $table = new SimpleTable;
                $table->addHeaderRow('Offset', 'Filename');
                for (sort { $a <=> $b } keys %orphans )
                {
                    $table->addDataRow(decimalHex0x($_), $orphans{$_}{filename});
                    delete $cleanCentralEntries{ $_ };
                }

                $table->display();
            }
        }

        if (Nesting::encapsulationCount())
        {
            # Benign Nested zips
            # This is the use-case where a zip file is "stored" in another zip file.
            # NOT a zipbomb -- want the benign nested entries

            # Note: this is only active when scan is used

           my %outerEntries = map  { $_->localHeaderOffset => $_->outputFilename }
                              grep {
                                      $_->entryType == ZIP_CENTRAL_HDR_SIG &&
                                    ! $_->encapsulated && # not encapsulated
                                      $_->ldEntry && # central header has a local sibling
                                      $_->ldEntry->childrenCount && # local entry has embedded entries
                                    ! Nesting::childrenInCentralDir($_->ldEntry)
                                   }
                              values %{ Nesting::getEntriesByOffset() };

            if (keys %outerEntries)
            {
                my $count = scalar keys %outerEntries;
                info  undef, "Nested Zip files found: $count";

                my $table = new SimpleTable;
                $table->addHeaderRow('Offset', 'Filename');
                $table->addDataRow(decimalHex0x($_), $outerEntries{$_})
                    for sort { $a <=> $b } keys %outerEntries ;

                $table->display();
            }
        }

        if ($LocalDirectory->anyStreamedEntries)
        {
            # Check for a missing Data Descriptors

           my %missingDataDescriptor = map  {   $_->localHeaderOffset => $_->outputFilename }
                                       grep {   $_->entryType == ZIP_LOCAL_HDR_SIG &&
                                                $_->streamed &&
                                              ! $_->readDataDescriptor
                                            }
                              values %{ Nesting::getEntriesByOffset() };


            for my $offset (sort keys %missingDataDescriptor)
            {
                my $filename = $missingDataDescriptor{$offset};
                error  $offset, "Filename '$filename': Missing 'Data Descriptor'" ;
            }
        }

        {
            # compare local & central for duplicate entries (CD entries point to same local header)

           my %ByLocalOffset = map  {      $_->localHeaderOffset => $_ }
                               grep {
                                           $_->entryType == ZIP_LOCAL_HDR_SIG # Want Local Headers
                                      && ! $_->encapsulated                   # Not encapsulated
                                      && @{ $_->getCdEntries } > 1
                                    }
                               values %{ Nesting::getEntriesByOffset() };

            for my $offset (sort keys %ByLocalOffset)
            {
                my @entries =  @{ $ByLocalOffset{$offset}->getCdEntries };
                if (@entries > 1)
                {
                    # found duplicates
                    my $localEntry =  $LocalDirectory->getByLocalOffset($offset) ;
                    if ($localEntry)
                    {
                        error undef, "Possible zipbomb -- Duplicate Central Headers referring to one Local header for '" . $localEntry->outputFilename . "' at offset " . decimalHex0x($offset);
                    }
                    else
                    {
                        error undef, "Possible zipbomb -- Duplicate Central Headers referring to one Local header at offset " . decimalHex0x($offset);
                    }

                    my $table = new SimpleTable;
                    $table->addHeaderRow('Offset', 'Filename');
                    for (sort { $a->centralHeaderOffset <=> $b->centralHeaderOffset } @entries)
                    {
                        $table->addDataRow(decimalHex0x($_->centralHeaderOffset), $_->outputFilename);
                        delete $cleanCentralEntries{ $_->centralHeaderOffset };
                    }

                    $table->display();
                }
            }
        }

        if (Nesting::encapsulationCount())
        {
            # compare local & central for nested entries

            # get the local offsets referenced in the CD
            # this deliberately ignores any valid nested local entries
            my @localOffsets = sort { $a <=> $b } keys %{ $CentralDirectory->{byLocalOffset} };

            # now check for nesting

            my %nested ;
            my %bomb;

            for my $offset (@localOffsets)
            {
                my $innerEntry = $LocalDirectory->{byLocalOffset}{$offset};
                if ($innerEntry)
                {
                    my $outerLocalEntry = Nesting::getOuterEncapsulation($innerEntry);
                    if (defined $outerLocalEntry)
                    {
                        my $outerOffset = $outerLocalEntry->localHeaderOffset();
                        if ($CentralDirectory->{byLocalOffset}{ $offset })
                        {
                            push @{ $bomb{ $outerOffset } }, $offset ;
                        }
                        else
                        {
                            push @{ $nested{ $outerOffset } }, $offset ;
                        }
                    }
                }
            }

            if (keys %nested)
            {
                # The real central directory at eof does not know about these.
                # likely to be a zip file stored in another zip file
                warning  undef, "Nested Local Entries found";
                for my $loc (sort keys %nested)
                {
                    my $count = scalar @{ $nested{$loc} };
                    my $outerEntry = $LocalDirectory->getByLocalOffset($loc);
                    say "Local Header for '" . $outerEntry->outputFilename . "' at offset " . decimalHex0x($loc) .  " has $count nested Local Headers";
                    for my $n ( @{ $nested{$loc} } )
                    {
                        my $innerEntry = $LocalDirectory->getByLocalOffset($n);

                        say "#  Nested Local Header for filename '" . $innerEntry->outputFilename . "' is at Offset " . decimalHex0x($n)  ;
                    }
                }
            }

            if (keys %bomb)
            {
                # Central Directory knows about these, so this is a zipbomb

                error undef, "Possible zipbomb -- Nested Local Entries found";
                for my $loc (sort keys %bomb)
                {
                    my $count = scalar @{ $bomb{$loc} };
                    my $outerEntry = $LocalDirectory->getByLocalOffset($loc);
                    say "# Local Header for '" . $outerEntry->outputFilename . "' at offset " . decimalHex0x($loc) .  " has $count nested Local Headers";

                    my $table = new SimpleTable;
                    $table->addHeaderRow('Offset', 'Filename');
                    $table->addDataRow(decimalHex0x($_), $LocalDirectory->getByLocalOffset($_)->outputFilename)
                        for sort @{ $bomb{$loc} } ;

                    $table->display();

                    delete $cleanCentralEntries{ $_ }
                        for grep { defined $_ }
                            map  { $CentralDirectory->{byLocalOffset}{$_}{centralHeaderOffset} }
                            @{ $bomb{$loc} } ;
                }
            }
        }

        # Check if contents of local headers match with central headers
        #
        # When central header encryption is used the local header values are masked (see APPNOTE 6.3.10, sec 4)
        # In this usecase the central header will appear to be absent
        #
        # key fields
        #    filename, compressed/uncompessed lengths, crc, compression method
        {
            for my $centralEntry ( sort { $a->centralHeaderOffset() <=> $b->centralHeaderOffset() } values %cleanCentralEntries )
            {
                my $localOffset = $centralEntry->localHeaderOffset;
                my $localEntry = $LocalDirectory->getByLocalOffset($localOffset);

                next
                    unless $localEntry;

                state $fields = [
                    # field name         offset    display name         stringify
                    ['filename',            ZIP_CD_FILENAME_OFFSET,
                                                'Filename',             undef, ],
                    ['extractVersion',       7, 'Extract Zip Spec',     sub { decimalHex0xUndef($_[0]) . " " . decodeZipVer($_[0]) }, ],
                    ['generalPurposeFlags',  8, 'General Purpose Flag', \&decimalHex0xUndef, ],
                    ['compressedMethod',    10, 'Compression Method',   sub { decimalHex0xUndef($_[0]) . " " . getcompressionMethodName($_[0]) }, ],
                    ['lastModDateTime',     12, 'Modification Time',    sub { decimalHex0xUndef($_[0]) . " " . LastModTime($_[0]) }, ],
                    ['crc32',               16, 'CRC32',                \&decimalHex0xUndef, ],
                    ['compressedSize',      20, 'Compressed Size',      \&decimalHex0xUndef, ],
                    ['uncompressedSize',    24, 'Uncompressed Size',    \&decimalHex0xUndef, ],

                ] ;

                my $table = new SimpleTable;
                $table->addHeaderRow('Field Name', 'Central Offset', 'Central Value', 'Local Offset', 'Local Value');

                for my $data (@$fields)
                {
                    my ($field, $offset, $name, $stringify) = @$data;
                    # if the local header uses streaming and we are running a scan/walk, the compressed/uncompressed sizes will not be known
                    my $localValue = $localEntry->{$field} ;
                    my $centralValue = $centralEntry->{$field};

                    if (($localValue // '-1') ne ($centralValue // '-2'))
                    {
                        if ($stringify)
                        {
                            $localValue = $stringify->($localValue);
                            $centralValue = $stringify->($centralValue);
                        }

                        $table->addDataRow($name,
                                            decimalHex0xUndef($centralEntry->centralHeaderOffset() + $offset),
                                            $centralValue,
                                            decimalHex0xUndef($localOffset+$offset),
                                            $localValue);
                    }
                }

                my $badFields = $table->hasData;
                if ($badFields)
                {
                    error undef, "Found $badFields Field Mismatch for Filename '". $centralEntry->outputFilename . "'";
                    $table->display();
                }
            }
        }

    }
    elsif ($CentralDirectory->exists())
    {
        my @messages = "Central Directory exists, but Local Directory not found" ;
        push @messages , "Try running with --walk' or '--scan' options"
            unless $opt_scan || $opt_walk ;
        error undef, @messages;
    }
    elsif ($LocalDirectory->exists())
    {
        if ($CentralDirectory->isEncryptedCD())
        {
            warning undef, "Local Directory exists, but Central Directory is encrypted"
        }
        else
        {
            error undef, "Local Directory exists, but Central Directory not found"
        }

    }

    if ($ErrorCount ||$WarningCount || $InfoCount )
    {
        say "#"
            unless $lastWasMessage ;

        say "# Error Count: $ErrorCount"
            if $ErrorCount;
        say "# Warning Count: $WarningCount"
            if $WarningCount;
        say "# Info Count: $InfoCount"
            if $InfoCount;
    }

    if (@Messages)
    {
        my $count = scalar @Messages ;
        say "#\nWARNINGS";
        say "# * $_\n" for @Messages ;
    }

    say "#\n# Done";
}

sub checkForBadlyFormedDataDescriptor
{
    my $lastHeader = shift;
    my $delta = shift // 0;

    # check size of delta - a DATA HDR without a signature can only be
    #     12 bytes for 32-bit
    #     20 bytes for 64-bit

    my $here = $FH->tell();

    my $localEntry = $lastHeader->{entry};

    return 0
        unless $opt_scan || $opt_walk ;

    # delta can be the actual payload + a data descriptor without a sig

    my $signature = unpack "V",  peekAtOffset($here + $delta, 4);

    if ($signature == ZIP_DATA_HDR_SIG)
    {
        return 0;
    }

    my $cl32 = unpack "V",  peekAtOffset($here + $delta - 8,  4);
    my $cl64 = unpack "Q<", peekAtOffset($here + $delta - 16, 8);

    if ($cl32 == $delta - 12)
    {
        return 12;
    }

    if ($cl64 == $delta - 20)
    {
        return 20 ;
    }

    return 0;
}


sub BadlyFormedDataDescriptor
{
    my $lastHeader= shift;
    my $delta = shift;

    # check size of delta - a DATA HDR without a signature can only be
    #     12 bytes for 32-bit
    #     20 bytes for 64-bit

    my $here = $FH->tell();

    my $localEntry = $lastHeader->{entry};
    my $compressedSize = $lastHeader->{payloadLength} ;

    my $sigName = Signatures::titleName(ZIP_DATA_HDR_SIG);

    if ($opt_scan || $opt_walk)
    {
        # delta can be the actual payload + a data descriptor without a sig

        if ($lastHeader->{'gotDataDescriptorSize'} == 12)
        {
            # seekTo($FH->tell() + $delta - 12) ;

            # outSomeData($delta - 12, "PAYLOAD", $opt_Redact) ;

            print "\n";
            out1 "Missing $sigName Signature", Value_V(ZIP_DATA_HDR_SIG);

            error $FH->tell(), "Missimg $sigName Signature";
            $localEntry->crc32(              out_V "CRC");
            $localEntry->compressedSize(   out_V "Compressed Size");
            $localEntry->uncompressedSize( out_V "Uncompressed Size");

            if ($localEntry->zip64)
            {
                error $here, "'$sigName': expected 64-bit values, got 32-bit";
            }

            return $FH->tell();
        }

        if ($lastHeader->{'gotDataDescriptorSize'} == 20)
        {
            # seekTo($FH->tell() + $delta - 20) ;

            # outSomeData($delta - 20, "PAYLOAD", $opt_Redact) ;

            print "\n";
            out1 "Missing $sigName Signature", Value_V(ZIP_DATA_HDR_SIG);

            error $FH->tell(), "Missimg $sigName Signature";
            $localEntry->crc32(              out_V "CRC");
            $localEntry->compressedSize(   out_Q "Compressed Size");
            $localEntry->uncompressedSize( out_Q "Uncompressed Size");

            if (! $localEntry->zip64)
            {
                error $here, "'$sigName': expected 32-bit values, got 64-bit";
            }

            return $FH->tell();
        }

        error 0, "MISSING $sigName";

        seekTo($here);
        return 0;
    }

    my $cdEntry = $localEntry->getCdEntry;

    if ($delta == 12)
    {
        $FH->seek($lastHeader->{payloadOffset} + $lastHeader->{payloadLength}, SEEK_SET) ;

        my $cl = unpack "V", peekAtOffset($FH->tell() + 4, 4);
        if ($cl == $compressedSize)
        {
            print "\n";
            out1 "Missing $sigName Signature", Value_V(ZIP_DATA_HDR_SIG);

            error $FH->tell(), "Missimg $sigName Signature";
            $localEntry->crc32(              out_V "CRC");
            $localEntry->compressedSize(   out_V "Compressed Size");
            $localEntry->uncompressedSize( out_V "Uncompressed Size");

            if ($localEntry->zip64)
            {
                error $here, "'$sigName': expected 64-bit values, got 32-bit";
            }

            return $FH->tell();
        }
    }

    if ($delta == 20)
    {
        $FH->seek($lastHeader->{payloadOffset} + $lastHeader->{payloadLength}, SEEK_SET) ;

        my $cl = unpack "Q<", peekAtOffset($FH->tell() + 4, 8);

        if ($cl == $compressedSize)
        {
            print "\n";
            out1 "Missing $sigName Signature", Value_V(ZIP_DATA_HDR_SIG);

            error $FH->tell(), "Missimg $sigName Signature";
            $localEntry->crc32(              out_V "CRC");
            $localEntry->compressedSize(   out_Q "Compressed Size");
            $localEntry->uncompressedSize( out_Q "Uncompressed Size");

            if (! $localEntry->zip64 && ( $cdEntry && ! $cdEntry->zip64))
            {
                error $here, "'$sigName': expected 32-bit values, got 64-bit";
            }

            return $FH->tell();
        }
    }

    seekTo($here);

    error $here, "Missing $sigName";
    return 0;
}

sub getcompressionMethodName
{
    my $id = shift ;
    " '" . ($ZIP_CompressionMethods{$id} || "Unknown Method") . "'" ;
}

sub compressionMethod
{
    my $id = shift ;
    Value_v($id) . getcompressionMethodName($id);
}

sub LocalHeader
{
    my $signature = shift ;
    my $data = shift ;
    my $startRecordOffset = shift ;

    my $locHeaderOffset = $FH->tell() -4 ;

    ++ $LocalHeaderCount;
    print "\n";
    out $data, "LOCAL HEADER #$LocalHeaderCount" , Value_V($signature);

    need 26, Signatures::name($signature);

    my $buffer;
    my $orphan = 0;

    my ($loc, $CDcompressedSize, $cdZip64, $zip64Sizes, $cdIndex, $cdEntryOffset) ;
    my $CentralEntryExists = $CentralDirectory->localOffset($startRecordOffset);
    my $localEntry = LocalDirectoryEntry->new();

    my $cdEntry;

    if (! $opt_scan && ! $opt_walk && $CentralEntryExists)
    {
        $cdEntry = $CentralDirectory->getByLocalOffset($startRecordOffset);

        if (! $cdEntry)
        {
            out1 "Orphan Entry: No matching central directory" ;
            $orphan = 1 ;
        }

        $cdZip64 = $cdEntry->zip64ExtraPresent;
        $zip64Sizes = $cdEntry->zip64SizesPresent;
        $cdEntryOffset = $cdEntry->centralHeaderOffset ;
        $localEntry->addCdEntry($cdEntry) ;

        if ($cdIndex && $cdIndex != $LocalHeaderCount)
        {
            # fatal undef, "$cdIndex != $LocalHeaderCount"
        }
    }

    my $extractVer = out_C  "Extract Zip Spec", \&decodeZipVer;
    out_C  "Extract OS", \&decodeOS;

    my ($bgp, $gpFlag) = read_v();
    my ($bcm, $compressedMethod) = read_v();

    out $bgp, "General Purpose Flag", Value_v($gpFlag) ;
    GeneralPurposeBits($compressedMethod, $gpFlag);
    my $LanguageEncodingFlag = $gpFlag & ZIP_GP_FLAG_LANGUAGE_ENCODING ;
    my $streaming = $gpFlag & ZIP_GP_FLAG_STREAMING_MASK ;
    $localEntry->languageEncodingFlag($LanguageEncodingFlag) ;

    out $bcm, "Compression Method",   compressionMethod($compressedMethod) ;
    info $FH->tell() - 2, "Unknown 'Compression Method' ID " . decimalHex0x($compressedMethod, 2)
        if ! defined $ZIP_CompressionMethods{$compressedMethod} ;

    my $lastMod = out_V "Modification Time", sub { LastModTime($_[0]) };

    my $crc              = out_V "CRC";
    warning $FH->tell() - 4, "CRC field should be zero when streaming is enabled"
        if $streaming && $crc != 0 ;

    my $compressedSize   = out_V "Compressed Size";
    # warning $FH->tell(), "Compressed Size should be zero when streaming is enabled";

    my $uncompressedSize = out_V "Uncompressed Size";
    # warning $FH->tell(), "Uncompressed Size should be zero when streaming is enabled";

    my $filenameLength   = out_v "Filename Length";

    if ($filenameLength == 0)
    {
        info $FH->tell()- 2, "Zero Length filename";
    }

    my $extraLength        = out_v "Extra Length";

    my $filename = '';
    if ($filenameLength)
    {
        need $filenameLength, Signatures::name($signature), 'Filename';

        myRead(my $raw_filename, $filenameLength);
        $localEntry->filename($raw_filename) ;
        $filename = outputFilename($raw_filename, $LanguageEncodingFlag);
        $localEntry->outputFilename($filename);
    }

    $localEntry->localHeaderOffset($locHeaderOffset) ;
    $localEntry->offsetStart($locHeaderOffset) ;
    $localEntry->compressedSize($compressedSize) ;
    $localEntry->uncompressedSize($uncompressedSize) ;
    $localEntry->extractVersion($extractVer);
    $localEntry->generalPurposeFlags($gpFlag);
    $localEntry->lastModDateTime($lastMod);
    $localEntry->crc32($crc) ;
    $localEntry->zip64ExtraPresent($cdZip64) ;
    $localEntry->zip64SizesPresent($zip64Sizes) ;

    $localEntry->compressedMethod($compressedMethod) ;
    $localEntry->streamed($gpFlag & ZIP_GP_FLAG_STREAMING_MASK) ;

    $localEntry->std_localHeaderOffset($locHeaderOffset + $PREFIX_DELTA) ;
    $localEntry->std_compressedSize($compressedSize) ;
    $localEntry->std_uncompressedSize($uncompressedSize) ;
    $localEntry->std_diskNumber(0) ;

    if ($extraLength)
    {
        need $extraLength, Signatures::name($signature), 'Extra';
        walkExtra($extraLength, $localEntry);
    }

    # APPNOTE 6.3.10, sec 4.3.8
    warning $FH->tell - $filenameLength, "Directory '$filename' must not have a payload"
        if ! $streaming && $filename =~ m#/$# && $localEntry->uncompressedSize ;

    my @msg ;
    # if ($cdZip64 && ! $ZIP64)
    # {
    #     # Central directory said this was Zip64
    #     # some zip files don't have the Zip64 field in the local header
    #     # seems to be a streaming issue.
    #     push @msg, "Missing Zip64 extra field in Local Header #$hexHdrCount\n";

    #     if (! $zip64Sizes)
    #     {
    #         # Central has a ZIP64 entry that doesn't have sizes
    #         # Local doesn't have a Zip 64 at all
    #         push @msg, "Unzip may complain about 'overlapped components' #$hexHdrCount\n";
    #     }
    #     else
    #     {
    #         $ZIP64 = 1
    #     }
    # }


    my $minizip_encrypted = $localEntry->minizip_secure;
    my $pk_encrypted      = ($gpFlag & ZIP_GP_FLAG_STRONG_ENCRYPTED_MASK) && $compressedMethod != 99 && ! $minizip_encrypted;

    # Detecting PK strong encryption from a local header is a bit convoluted.
    # Cannot just use ZIP_GP_FLAG_ENCRYPTED_CD because minizip also uses this bit.
    # so jump through some hoops
    #     extract ver is >= 5.0'
    #     all the encryption flags are set in gpflags
    #     TODO - add zero lengths for crc, compresssed & uncompressed

    if (($gpFlag & ZIP_GP_FLAG_ALL_ENCRYPT) == ZIP_GP_FLAG_ALL_ENCRYPT  && $extractVer >= 0x32  )
    {
        $CentralDirectory->setPkEncryptedCD()
    }

    my $size = 0;

    # If no CD scanned, get compressed Size from local header.
    # Zip64 extra field takes priority
    my $cdl = defined $cdEntry
                ? $cdEntry->compressedSize()
                : undef;

    $CDcompressedSize = $localEntry->compressedSize ;
    $CDcompressedSize = $cdl
        if defined $cdl && $gpFlag & ZIP_GP_FLAG_STREAMING_MASK;

    my $cdu = defined $CentralDirectory->{byLocalOffset}{$locHeaderOffset}
                ? $CentralDirectory->{byLocalOffset}{$locHeaderOffset}{uncompressedSize}
                : undef;
    my $CDuncompressedSize = $localEntry->uncompressedSize ;

    $CDuncompressedSize = $cdu
        if defined $cdu && $gpFlag & ZIP_GP_FLAG_STREAMING_MASK;

    my $fullCompressedSize = $CDcompressedSize;

    my $payloadOffset = $FH->tell();
    $localEntry->payloadOffset($payloadOffset) ;
    $localEntry->offsetEnd($payloadOffset + $fullCompressedSize -1) ;

    if ($CDcompressedSize)
    {
        # check if enough left in file for the payload
        my $available = $FILELEN - $FH->tell;
        if ($available < $CDcompressedSize )
        {
            error $FH->tell,
                  "file truncated while reading 'PAYLOAD'",
                  expectedMessage($CDcompressedSize, $available);

            $CDcompressedSize = $available;
        }
    }

    # Next block can decrement the CDcompressedSize
    # possiblty to zero. Need to remember if it started out
    # as a non-zero value
    my $haveCDcompressedSize = $CDcompressedSize;

    if ($compressedMethod == 99 && $localEntry->aesValid) # AES Encryption
    {
        $CDcompressedSize -= printAes($localEntry)
    }
    elsif (($gpFlag & ZIP_GP_FLAG_ALL_ENCRYPT) == 0)
    {
        if ($compressedMethod == ZIP_CM_LZMA)
        {

            $size = printLzmaProperties()
        }

        $CDcompressedSize -= $size;
    }
    elsif ($pk_encrypted)
    {
        $CDcompressedSize -= DecryptionHeader();
    }

    if ($haveCDcompressedSize) {

        if ($compressedMethod == 92 && $CDcompressedSize == 20) {
            # Payload for a Reference is the SHA-1 hash of the uncompressed content
            myRead(my $sha1, 20);
            out $sha1, "PAYLOAD",  "SHA-1 Hash: " . hexDump($sha1);
        }
        elsif ($compressedMethod == 99 && $localEntry->aesValid ) {
            outSomeData($CDcompressedSize, "PAYLOAD", $opt_Redact) ;
            my $auth ;
            myRead($auth, 10);
            out $auth, "AES Auth",  hexDump16($auth);
        }
        else {
            outSomeData($CDcompressedSize, "PAYLOAD", $opt_Redact) ;
        }
    }

    print "WARNING: $_"
        for @msg;

    push @Messages, @msg ;

    $LocalDirectory->addEntry($localEntry);

    return {
                'localHeader'   => 1,
                'streamed'      => $gpFlag & ZIP_GP_FLAG_STREAMING_MASK,
                'offset'        => $startRecordOffset,
                'length'        => $FH->tell() - $startRecordOffset,
                'payloadLength' => $fullCompressedSize,
                'payloadOffset' => $payloadOffset,
                'entry'         => $localEntry,
        } ;
}

use constant Pack_ZIP_DIGITAL_SIGNATURE_SIG => pack("V", ZIP_DIGITAL_SIGNATURE_SIG);

sub findDigitalSignature
{
    my $cdSize = shift;

    my $here = $FH->tell();

    my $data ;
    myRead($data, $cdSize);

    seekTo($here);

    # find SIG
    my $ix = index($data, Pack_ZIP_DIGITAL_SIGNATURE_SIG);
    if ($ix > -1)
    {
        # check size of signature meaans it is directly after the encrypted CD
        my $sigSize = unpack "v", substr($data, $ix+4, 2);
        if ($ix + 4 + 2 + $sigSize == $cdSize)
        {
            # return size of digital signature record
            return 4 + 2 + $sigSize ;
        }
    }

    return 0;
}

sub displayEncryptedCD
{
    # First thing in the encrypted CD is the Decryption Header
    my $decryptHeaderSize = DecryptionHeader(1);

    # Check for digital signature record in the CD
    # It needs to be the very last thing in the CD

    my $delta = deltaToNextSignature();
    print "\n";
    outSomeData($delta, "ENCRYPTED CENTRAL DIRECTORY")
        if $delta;
}

sub DecryptionHeader
{
    # APPNOTE 6.3.10, sec 7.2.4

    # -Decryption Header:
    # Value     Size     Description
    # -----     ----     -----------
    # IVSize    2 bytes  Size of initialization vector (IV)
    # IVData    IVSize   Initialization vector for this file
    # Size      4 bytes  Size of remaining decryption header data
    # Format    2 bytes  Format definition for this record
    # AlgID     2 bytes  Encryption algorithm identifier
    # Bitlen    2 bytes  Bit length of encryption key
    # Flags     2 bytes  Processing flags
    # ErdSize   2 bytes  Size of Encrypted Random Data
    # ErdData   ErdSize  Encrypted Random Data
    # Reserved1 4 bytes  Reserved certificate processing data
    # Reserved2 (var)    Reserved for certificate processing data
    # VSize     2 bytes  Size of password validation data
    # VData     VSize-4  Password validation data
    # VCRC32    4 bytes  Standard ZIP CRC32 of password validation data

    my $central = shift ;

    if ($central)
    {
        print "\n";
        out "", "CENTRAL HEADER DECRYPTION RECORD";

    }
    else
    {
        print "\n";
        out "", "DECRYPTION HEADER RECORD";
    }

    my $bytecount = 2;

    my $IVSize = out_v "IVSize";
    outHexdump($IVSize, "IVData");
    $bytecount += $IVSize;

    my $Size = out_V "Size";
    $bytecount += $Size + 4;

    out_v "Format";
    out_v "AlgId", sub { $AlgIdLookup{ $_[0] } // "Unknown algorithm" } ;
    out_v "BitLen";
    out_v "Flags", sub { $FlagsLookup{ $_[0] } // "Reserved for certificate processing" } ;

    my $ErdSize = out_v "ErdSize";
    outHexdump($ErdSize, "ErdData");

    my $Reserved1_RCount = out_V "RCount";
    Reserved2($Reserved1_RCount);

    my $VSize = out_v "VSize";
    outHexdump($VSize-4, "VData");

    out_V "VCRC32";

    return $bytecount ;
}

sub Reserved2
{
    # APPNOTE 6.3.10, sec 7.4.3 & 7.4.4

    my $recipients = shift;

    return 0
        if $recipients == 0;

    out_v "HashAlg", sub { $HashAlgLookup{ $_[0] } // "Unknown algorithm" } ;
    my $HSize = out_v "HSize" ;

    my $ix = 1;
    for (0 .. $recipients-1)
    {
        my $hex = sprintf("Key #%X", $ix) ;
        my $RESize = out_v "RESize $hex";

        outHexdump($HSize, "REHData $hex");
        outHexdump($RESize - $HSize, "REKData $hex");

        ++ $ix;
    }
}

sub redactData
{
    my $data = shift;

    # Redact everything apart from directory seperators
    $data =~ s(.)(X)g
        if $opt_Redact;

    return $data;
}

sub redactFilename
{
    my $filename = shift;

    # Redact everything apart from directory seperators
    $filename =~ s(.)(X)g
        if $opt_Redact;

    return $filename;
}

sub validateDirectory
{
    # Check that Directries are stored correctly
    #
    # 1. Filename MUST end with a "/"
    #    see APPNOTE 6.3.10, sec 4.3.8
    # 2. Uncompressed size == 0
    #    see APPNOTE 6.3.10, sec 4.3.8
    # 3. warn if compressed size > 0 and Uncompressed size == 0
    # 4. check for presence of DOS directory attrib in External Attributes
    # 5. Check for Unix  extrnal attribute S_IFDIR

    my $offset = shift ;
    my $filename = shift ;
    my $extractVersion = shift;
    my $versionMadeBy = shift;
    my $compressedSize = shift;
    my $uncompressedSize = shift;
    my $externalAttributes = shift;

    my $dosAttributes = $externalAttributes & 0xFFFF;
    my $otherAttributes = ($externalAttributes >> 16 ) &  0xFFFF;

    my $probablyDirectory = 0;
    my $filenameOK = 0;
    my $attributesSet = 0;
    my $dosAttributeSet = 0;
    my $unixAttributeSet = 0;

    if ($filename =~ m#/$#)
    {
        # filename claims it is a directory.
        $probablyDirectory = 1;
        $filenameOK = 1;
    }

    if ($dosAttributes & 0x0010) # ATTR_DIRECTORY
    {
        $probablyDirectory = 1;
        $attributesSet = 1 ;
        $dosAttributeSet = 1 ;
    }

    if ($versionMadeBy == 3 && $otherAttributes & 0x4000) # Unix & S_IFDIR
    {
        $probablyDirectory = 1;
        $attributesSet = 1;
        $unixAttributeSet = 1;
    }

    return
        unless $probablyDirectory ;

    error $offset + CentralDirectoryEntry::Offset_Filename(),
            "Directory '$filename' must end in a '/'",
            "'External Attributes' flag this as a directory"
        if ! $filenameOK && $uncompressedSize == 0;

    info $offset + CentralDirectoryEntry::Offset_ExternalAttributes(),
            "DOS Directory flag not set in 'External Attributes' for Directory '$filename'"
        if $filenameOK && ! $dosAttributeSet;

    info $offset + CentralDirectoryEntry::Offset_ExternalAttributes(),
            "Unix Directory flag not set in 'External Attributes' for Directory '$filename'"
        if $filenameOK && $versionMadeBy == 3 && ! $unixAttributeSet;

    if ($uncompressedSize != 0)
    {
        # APPNOTE 6.3.10, sec 4.3.8
        error $offset + CentralDirectoryEntry::Offset_UncompressedSize(),
                "Directory '$filename' must not have a payload"
    }
    elsif ($compressedSize != 0)
    {

        info $offset + CentralDirectoryEntry::Offset_CompressedSize(),
                "Directory '$filename' has compressed payload that uncompresses to nothing"
    }

    if ($extractVersion < 20)
    {
        # APPNOTE 6.3.10, sec 4.4.3.2
        my $got = decodeZipVer($extractVersion);
        warning $offset + CentralDirectoryEntry::Offset_VersionNeededToExtract(),
                "'Extract Zip Spec' is '$got'. Need value >= '2.0' for Directory '$filename'"
    }
}

sub validateFilename
{
    my $filename = shift ;

    return "Zero length filename"
        if $filename eq '' ;

    # TODO
    # - check length of filename
    #   getconf NAME_MAX . and getconf PATH_MAX . on Linux

    # Start with APPNOTE restrictions

    # APPNOTE 6.3.10, sec 4.4.17.1
    #
    # No absolute path
    # No backslash delimeters
    # No drive letters

    return "Filename must not be an absolute path"
        if $filename =~ m#^/#;

    return ["Backslash detected in filename", "Possible Windows path."]
        if $filename =~ m#\\#;

    return "Windows Drive Letter '$1' not allowed in filename"
        if $filename =~ /^([a-z]:)/i ;

    # Slip Vulnerability with use of ".." in a relative path
    # https://security.snyk.io/research/zip-slip-vulnerability
    return ["Use of '..' in filename is a Zip Slip Vulnerability",
            "See https://security.snyk.io/research/zip-slip-vulnerability" ]
        if $filename =~ m#^\.\./# || $filename =~ m#/\.\./# || $filename =~ m#/\.\.# ;

    # Cannot have "." or ".." as the full filename
    return "Use of current-directory filename '.' may not unzip correctly"
        if $filename eq '.' ;

    return "Use of parent-directory filename '..' may not unzip correctly"
        if $filename eq '..' ;

    # Portability (mostly with Windows)

    {
        # see https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file
        state $badDosFilename = join '|', map { quotemeta }
                                qw(CON  PRN  AUX  NUL
                                COM1 COM2 COM3 COM4 COM5 COM6 COM7 COM8 COM9
                                LPT1 LPT2 LPT3 LPT4 LPT5 LPT6 LPT7 LPT8 LPT9
                                ) ;

        # if $filename contains any invalid codepoints, we will get a warning like this
        #
        #   Operation "pattern match (m//)" returns its argument for non-Unicode code point
        #
        # so silence it for now.

        no warnings;

        return "Portability Issue: '$1' is a reserved Windows device name"
            if $filename =~ /^($badDosFilename)$/io ;

        # Can't have the device name with an extension either
        return "Portability Issue: '$1' is a reserved Windows device name"
            if $filename =~ /^($badDosFilename)\./io ;
    }

    state $illegal_windows_chars = join '|', map { quotemeta } qw( < > : " | ? * );
    return "Portability Issue: Windows filename cannot contain '$1'"
        if  $filename =~ /($illegal_windows_chars)/o ;

    return "Portability Issue: Null character '\\x00' is not allowed in a Windows or Linux filename"
        if  $filename =~ /\x00/ ;

    return sprintf "Portability Issue: Control character '\\x%02X' is not allowed in a Windows filename", ord($1)
        if  $filename =~ /([\x00-\x1F])/ ;

    return undef;
}

sub getOutputFilename
{
    my $raw_filename = shift;
    my $LanguageEncodingFlag = shift;
    my $message = shift // "Filename";

    my $filename ;
    my $decoded_filename;

    if ($raw_filename eq '')
    {
        if ($message eq 'Filename')
        {
            warning $FH->tell() ,
                "Filename ''",
                "Zero Length Filename" ;
        }

        return '', '', 0;
    }
    elsif ($opt_Redact)
    {
        return redactFilename($raw_filename), '', 0 ;
    }
    else
    {
        $decoded_filename = TextEncoding::decode($raw_filename, $message, $LanguageEncodingFlag) ;
        $filename = TextEncoding::encode($decoded_filename, $message, $LanguageEncodingFlag) ;
    }

    return $filename, $decoded_filename, $filename ne $raw_filename ;
}

sub outputFilename
{
    my $raw_filename = shift;
    my $LanguageEncodingFlag = shift;
    my $message = shift // "Filename";

    my ($filename, $decoded_filename, $modified) = getOutputFilename($raw_filename, $LanguageEncodingFlag);

    out $raw_filename, $message,  "'". $filename . "'";

    if (! $opt_Redact && TextEncoding::debugEncoding())
    {
        # use Devel::Peek;
        # print "READ     " ; Dump($raw_filename);
        # print "INTERNAL " ; Dump($decoded_filename);
        # print "OUTPUT   " ; Dump($filename);

        debug $FH->tell() - length($raw_filename),
                    "$message Encoding Change"
            if $modified ;

        # use Unicode::Normalize;
        # my $NormaizedForm ;
        # if (defined $decoded_filename)
        # {
        #     $NormaizedForm .= Unicode::Normalize::checkNFD  $decoded_filename ? 'NFD ' : '';
        #     $NormaizedForm .= Unicode::Normalize::checkNFC  $decoded_filename ? 'NFC ' : '';
        #     $NormaizedForm .= Unicode::Normalize::checkNFKD $decoded_filename ? 'NFKD ' : '';
        #     $NormaizedForm .= Unicode::Normalize::checkNFKC $decoded_filename ? 'NFKC ' : '';
        #     $NormaizedForm .= Unicode::Normalize::checkFCD  $decoded_filename ? 'FCD ' : '';
        #     $NormaizedForm .= Unicode::Normalize::checkFCC  $decoded_filename ? 'FCC ' : '';
        # }

        debug $FH->tell() - length($raw_filename),
                    "Encoding Debug for $message",
                    "Octets Read from File  [$raw_filename][" . length($raw_filename). "] [" . charDump2($raw_filename) . "]",
                    "Via Unicode Codepoints [$decoded_filename][" . length($decoded_filename) . "] [" . charDump($decoded_filename) . "]",
                    # "Unicode Normalization  $NormaizedForm",
                    "Octets Written         [$filename][" . length($filename). "] [" . charDump2($filename) . "]";
    }

    if ($message eq 'Filename' && $opt_want_warning_mesages)
    {
        # Check for bad, unsafe & not portable filenames
        my $v = validateFilename($decoded_filename);

        if ($v)
        {
            my @v = ref $v eq 'ARRAY'
                        ? @$v
                        : $v;

            warning $FH->tell() - length($raw_filename),
                "Filename '$filename'",
                @v
        }
    }

    return $filename;
}

sub CentralHeader
{
    my $signature = shift ;
    my $data = shift ;
    my $startRecordOffset = shift ;

    my $cdEntryOffset = $FH->tell() - 4 ;

    ++ $CentralHeaderCount;

    print "\n";
    out $data, "CENTRAL HEADER #$CentralHeaderCount", Value_V($signature);
    my $buffer;

    need 42, Signatures::name($signature);

    out_C "Created Zip Spec", \&decodeZipVer;
    my $made_by = out_C "Created OS", \&decodeOS;
    my $extractVer = out_C "Extract Zip Spec", \&decodeZipVer;
    out_C "Extract OS", \&decodeOS;

    my ($bgp, $gpFlag) = read_v();
    my ($bcm, $compressedMethod) = read_v();

    my $cdEntry = CentralDirectoryEntry->new($cdEntryOffset);

    out $bgp, "General Purpose Flag", Value_v($gpFlag) ;
    GeneralPurposeBits($compressedMethod, $gpFlag);
    my $LanguageEncodingFlag = $gpFlag & ZIP_GP_FLAG_LANGUAGE_ENCODING ;
    $cdEntry->languageEncodingFlag($LanguageEncodingFlag) ;

    out $bcm, "Compression Method", compressionMethod($compressedMethod) ;
    info $FH->tell() - 2, "Unknown 'Compression Method' ID " . decimalHex0x($compressedMethod, 2)
        if ! defined $ZIP_CompressionMethods{$compressedMethod} ;

    my $lastMod = out_V "Modification Time", sub { LastModTime($_[0]) };

    my $crc                = out_V "CRC";
    my $compressedSize   = out_V "Compressed Size";
    my $std_compressedSize   = $compressedSize;
    my $uncompressedSize = out_V "Uncompressed Size";
    my $std_uncompressedSize = $uncompressedSize;
    my $filenameLength     = out_v "Filename Length";
    if ($filenameLength == 0)
    {
        info $FH->tell()- 2, "Zero Length filename";
    }
    my $extraLength        = out_v "Extra Length";
    my $comment_length     = out_v "Comment Length";
    my $disk_start         = out_v "Disk Start";
    my $std_disk_start     = $disk_start;

    my $int_file_attrib    = out_v "Int File Attributes";
    out1 "[Bit 0]",      $int_file_attrib & 1 ? "1 'Text Data'" : "0 'Binary Data'";
    out1 "[Bits 1-15]",  Value_v($int_file_attrib & 0xFE) . " 'Unknown'"
        if  $int_file_attrib & 0xFE ;

    my $ext_file_attrib    = out_V "Ext File Attributes";

    {
        # MS-DOS Attributes are bottom two bytes
        my $dos_attrib = $ext_file_attrib & 0xFFFF;

        # See https://learn.microsoft.com/en-us/windows/win32/fileio/file-attribute-constants
        # and https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb/65e0c225-5925-44b0-8104-6b91339c709f

        out1 "[Bit 0]",  "Read-Only"     if $dos_attrib & 0x0001 ;
        out1 "[Bit 1]",  "Hidden"        if $dos_attrib & 0x0002 ;
        out1 "[Bit 2]",  "System"        if $dos_attrib & 0x0004 ;
        out1 "[Bit 3]",  "Label"         if $dos_attrib & 0x0008 ;
        out1 "[Bit 4]",  "Directory"     if $dos_attrib & 0x0010 ;
        out1 "[Bit 5]",  "Archive"       if $dos_attrib & 0x0020 ;
        out1 "[Bit 6]",  "Device"        if $dos_attrib & 0x0040 ;
        out1 "[Bit 7]",  "Normal"        if $dos_attrib & 0x0080 ;
        out1 "[Bit 8]",  "Temporary"     if $dos_attrib & 0x0100 ;
        out1 "[Bit 9]",  "Sparse"        if $dos_attrib & 0x0200 ;
        out1 "[Bit 10]", "Reparse Point" if $dos_attrib & 0x0400 ;
        out1 "[Bit 11]", "Compressed"    if $dos_attrib & 0x0800 ;

        out1 "[Bit 12]", "Offline"       if $dos_attrib & 0x1000 ;
        out1 "[Bit 13]", "Not Indexed"   if $dos_attrib & 0x2000 ;

        # Zip files created on Mac seem to set this bit. Not clear why.
        out1 "[Bit 14]", "Possible Mac Flag"   if $dos_attrib & 0x4000 ;

        # p7Zip & 7z set this bit to flag that the high 16-bits are Unix attributes
        out1 "[Bit 15]", "Possible p7zip/7z Unix Flag"   if $dos_attrib & 0x8000 ;

    }

    my $native_attrib = ($ext_file_attrib >> 16 ) &  0xFFFF;

    if ($made_by == 3) # Unix
    {

        state $mask = {
                0   => '---',
                1   => '--x',
                2   => '-w-',
                3   => '-wx',
                4   => 'r--',
                5   => 'r-x',
                6   => 'rw-',
                7   => 'rwx',
            } ;

        my $rwx = ($native_attrib  &  0777);

        if ($rwx)
        {
            my $output  = '';
            $output .= $mask->{ ($rwx >> 6) & 07 } ;
            $output .= $mask->{ ($rwx >> 3) & 07 } ;
            $output .= $mask->{ ($rwx >> 0) & 07 } ;

            out1 "[Bits 16-24]",  Value_v($rwx)  . " 'Unix attrib: $output'" ;
            out1 "[Bit 25]",  "1 'Sticky'"
                if $rwx & 0x200 ;
            out1 "[Bit 26]",  "1 'Set GID'"
                if $rwx & 0x400 ;
            out1 "[Bit 27]",  "1 'Set UID'"
                if $rwx & 0x800 ;

            my $not_rwx = (($native_attrib  >> 12) & 0xF);
            if ($not_rwx)
            {
                state $masks = {
                    0x0C =>  'Socket',           # 0x0C  0b1100
                    0x0A =>  'Symbolic Link',    # 0x0A  0b1010
                    0x08 =>  'Regular File',     # 0x08  0b1000
                    0x06 =>  'Block Device',     # 0x06  0b0110
                    0x04 =>  'Directory',        # 0x04  0b0100
                    0x02 =>  'Character Device', # 0x02  0b0010
                    0x01 =>  'FIFO',             # 0x01  0b0001
                };

                my $got = $masks->{$not_rwx} // 'Unknown Unix attrib' ;
                out1 "[Bits 28-31]",  Value_C($not_rwx) . " '$got'"
            }
        }
    }
    elsif ($native_attrib)
    {
        out1 "[Bits 24-31]",  Value_v($native_attrib) . " 'Unknown attributes for OS ID $made_by'"
    }

    my ($d, $locHeaderOffset) = read_V();
    my $out = Value_V($locHeaderOffset);
    my $std_localHeaderOffset = $locHeaderOffset;

    if ($locHeaderOffset != MAX32)
    {
        testPossiblePrefix($locHeaderOffset, ZIP_LOCAL_HDR_SIG);
        if ($PREFIX_DELTA)
        {
            $out .= " [Actual Offset is " . Value_V($locHeaderOffset + $PREFIX_DELTA) . "]"
        }
    }

    out $d, "Local Header Offset", $out;

    if ($locHeaderOffset != MAX32)
    {
        my $commonMessage = "'Local Header Offset' field in '" . Signatures::name($signature) .  "' is invalid";
        $locHeaderOffset = checkOffsetValue($locHeaderOffset, $startRecordOffset, 0, $commonMessage, $startRecordOffset + CentralDirectoryEntry::Offset_RelativeOffsetToLocal(), ZIP_LOCAL_HDR_SIG) ;
    }

    my $filename = '';
    if ($filenameLength)
    {
        need $filenameLength, Signatures::name($signature), 'Filename';

        myRead(my $raw_filename, $filenameLength);
        $cdEntry->filename($raw_filename) ;
        $filename = outputFilename($raw_filename, $LanguageEncodingFlag);
        $cdEntry->outputFilename($filename);
    }

    $cdEntry->centralHeaderOffset($cdEntryOffset) ;
    $cdEntry->localHeaderOffset($locHeaderOffset) ;
    $cdEntry->compressedSize($compressedSize) ;
    $cdEntry->uncompressedSize($uncompressedSize) ;
    $cdEntry->zip64ExtraPresent(undef) ; #$cdZip64; ### FIX ME
    $cdEntry->zip64SizesPresent(undef) ; # $zip64Sizes;   ### FIX ME
    $cdEntry->extractVersion($extractVer);
    $cdEntry->generalPurposeFlags($gpFlag);
    $cdEntry->compressedMethod($compressedMethod) ;
    $cdEntry->lastModDateTime($lastMod);
    $cdEntry->crc32($crc) ;
    $cdEntry->inCentralDir(1) ;

    $cdEntry->std_localHeaderOffset($std_localHeaderOffset) ;
    $cdEntry->std_compressedSize($std_compressedSize) ;
    $cdEntry->std_uncompressedSize($std_uncompressedSize) ;
    $cdEntry->std_diskNumber($std_disk_start) ;

    if ($extraLength)
    {
        need $extraLength, Signatures::name($signature), 'Extra';

        walkExtra($extraLength, $cdEntry);
    }

    # $cdEntry->endCentralHeaderOffset($FH->tell() - 1);

    # Can only validate for directory after zip64 data is read
    validateDirectory($cdEntryOffset, $filename, $extractVer, $made_by,
        $cdEntry->compressedSize, $cdEntry->uncompressedSize, $ext_file_attrib);

    if ($comment_length)
    {
        need $comment_length, Signatures::name($signature), 'Comment';

        my $comment ;
        myRead($comment, $comment_length);
        outputFilename $comment, $LanguageEncodingFlag, "Comment";
        $cdEntry->comment($comment);
    }

    $cdEntry->offsetStart($cdEntryOffset) ;
    $cdEntry->offsetEnd($FH->tell() - 1) ;

    $CentralDirectory->addEntry($cdEntry);

    return { 'encapsulated' => $cdEntry ? $cdEntry->encapsulated() : 0};
}

sub decodeZipVer
{
    my $ver = shift ;

    return ""
        if ! defined $ver;

    my $sHi = int($ver /10) ;
    my $sLo = $ver % 10 ;

    "$sHi.$sLo";
}

sub decodeOS
{
    my $ver = shift ;

    $OS_Lookup{$ver} || "Unknown" ;
}

sub Zip64EndCentralHeader
{
    # Extra ID is 0x0001

    # APPNOTE 6.3.10, section 4.3.14, 7.3.3, 7.3.4 & APPENDIX C

    # TODO - APPNOTE allows an extensible data sector at end of this record (see APPNOTE 6.3.10, section 4.3.14.4)
    # The code below does NOT take this into account.

    my $signature = shift ;
    my $data = shift ;
    my $startRecordOffset = shift ;

    print "\n";
    out $data, "ZIP64 END CENTRAL DIR RECORD", Value_V($signature);

    need 8, Signatures::name($signature);

    my $size = out_Q "Size of record";

    need $size, Signatures::name($signature);

                              out_C  "Created Zip Spec", \&decodeZipVer;
                              out_C  "Created OS", \&decodeOS;
    my $extractSpec         = out_C  "Extract Zip Spec", \&decodeZipVer;
                              out_C  "Extract OS", \&decodeOS;
    my $diskNumber          = out_V  "Number of this disk";
    my $cdDiskNumber        = out_V  "Central Dir Disk no";
    my $entriesOnThisDisk   = out_Q  "Entries in this disk";
    my $totalEntries        = out_Q  "Total Entries";
    my $centralDirSize      = out_Q  "Size of Central Dir";

    my ($d, $centralDirOffset) = read_Q();
    my $out = Value_Q($centralDirOffset);
    testPossiblePrefix($centralDirOffset, ZIP_CENTRAL_HDR_SIG);

    $out .= " [Actual Offset is " . Value_Q($centralDirOffset + $PREFIX_DELTA) . "]"
        if $PREFIX_DELTA ;
    out $d, "Offset to Central dir", $out;

    if (! emptyArchive($startRecordOffset, $diskNumber, $cdDiskNumber, $entriesOnThisDisk, $totalEntries,  $centralDirSize, $centralDirOffset))
    {
        my $commonMessage = "'Offset to Central Directory' field in '" . Signatures::name($signature) . "' is invalid";
        $centralDirOffset = checkOffsetValue($centralDirOffset, $startRecordOffset, $centralDirSize, $commonMessage, $startRecordOffset + 48, ZIP_CENTRAL_HDR_SIG, 0, $extractSpec < 0x3E) ;
    }

    # Length of 44 means typical version 1 header
    return
        if $size == 44 ;

    my $remaining = $size - 44;

    # pkzip sets the extract zip spec to 6.2 (0x3E) to signal a v2 record
    # See APPNOTE 6.3.10, section, 7.3.3

    if ($extractSpec >= 0x3E)
    {
        # Version 2 header (see APPNOTE 6.3.7, section  7.3.4, )
        # Can use version 2 header to infer presence of encrypted CD
        $CentralDirectory->setPkEncryptedCD();


        # Compression Method    2 bytes    Method used to compress the
        #                                  Central Directory
        # Compressed Size       8 bytes    Size of the compressed data
        # Original   Size       8 bytes    Original uncompressed size
        # AlgId                 2 bytes    Encryption algorithm ID
        # BitLen                2 bytes    Encryption key length
        # Flags                 2 bytes    Encryption flags
        # HashID                2 bytes    Hash algorithm identifier
        # Hash Length           2 bytes    Length of hash data
        # Hash Data             (variable) Hash data

        my ($bcm, $compressedMethod) = read_v();
        out $bcm, "Compression Method", compressionMethod($compressedMethod) ;
        info $FH->tell() - 2, "Unknown 'Compression Method' ID " . decimalHex0x($compressedMethod, 2)
            if ! defined $ZIP_CompressionMethods{$compressedMethod} ;
        out_Q "Compressed Size";
        out_Q "Uncompressed Size";
        out_v "AlgId", sub { $AlgIdLookup{ $_[0] } // "Unknown algorithm" } ;
        out_v "BitLen";
        out_v "Flags", sub { $FlagsLookup{ $_[0] } // "reserved for certificate processing" } ;
        out_v "HashID", sub { $HashIDLookup{ $_[0] } // "Unknown ID" } ;

        my $hashLen = out_v "Hash Length ";
        outHexdump($hashLen, "Hash Data");

        $remaining -= $hashLen + 28;
    }

    my $entry = Zip64EndCentralHeaderEntry->new();

    if ($remaining)
    {
        # Handle 'zip64 extensible data sector' here
        # See APPNOTE 6.3.10, section 4.3.14.3, 4.3.14.4 & APPENDIX C
        # Not seen a real example of this. Tested with hand crafted files.
        walkExtra($remaining, $entry);
    }

    return {};
}


sub Zip64EndCentralLocator
{
    # APPNOTE 6.3.10, sec 4.3.15

    my $signature = shift ;
    my $data = shift ;
    my $startRecordOffset = shift ;

    print "\n";
    out $data, "ZIP64 END CENTRAL DIR LOCATOR", Value_V($signature);

    need 16, Signatures::name($signature);

    # my ($nextRecord, $deltaActuallyAvailable) = $HeaderOffsetIndex->checkForOverlap(16);

    # if ($deltaActuallyAvailable)
    # {
    #     fatal_truncated_record(
    #         sprintf("ZIP64 END CENTRAL DIR LOCATOR \@%X truncated", $FH->tell() - 4),
    #         sprintf("Need 0x%X bytes, have 0x%X available", 16, $deltaActuallyAvailable),
    #         sprintf("Next Record is %s \@0x%X", $nextRecord->name(), $nextRecord->offset())
    #         )
    # }

    # TODO - check values for traces of multi-part + crazy offsets
    out_V  "Central Dir Disk no";

    my ($d, $zip64EndCentralDirOffset) = read_Q();
    my $out = Value_Q($zip64EndCentralDirOffset);
    testPossiblePrefix($zip64EndCentralDirOffset, ZIP64_END_CENTRAL_REC_HDR_SIG);

    $out .= " [Actual Offset is " . Value_Q($zip64EndCentralDirOffset + $PREFIX_DELTA) . "]"
        if $PREFIX_DELTA ;
    out $d, "Offset to Zip64 EOCD", $out;

    my $totalDisks = out_V  "Total no of Disks";

    if ($totalDisks > 0)
    {
        my $commonMessage = "'Offset to Zip64 End of Central Directory Record' field in '" . Signatures::name($signature) . "' is invalid";
        $zip64EndCentralDirOffset = checkOffsetValue($zip64EndCentralDirOffset, $startRecordOffset, 0, $commonMessage, $FH->tell() - 12, ZIP64_END_CENTRAL_REC_HDR_SIG) ;
    }

    return {};
}

sub needZip64EOCDLocator
{
    # zip64 end of central directory field needed if any of the fields
    # in the End Central Header record are maxed out

    my $diskNumber          = shift ;
    my $cdDiskNumber        = shift ;
    my $entriesOnThisDisk   = shift ;
    my $totalEntries        = shift ;
    my $centralDirSize      = shift ;
    my $centralDirOffset    = shift ;

    return  (full16($diskNumber)        || # 4.4.19
             full16($cdDiskNumber)      || # 4.4.20
             full16($entriesOnThisDisk) || # 4.4.21
             full16($totalEntries)      || # 4.4.22
             full32($centralDirSize)    || # 4.4.23
             full32($centralDirOffset)     # 4.4.24
             ) ;
}

sub emptyArchive
{
    my $offset              = shift;
    my $diskNumber          = shift ;
    my $cdDiskNumber        = shift ;
    my $entriesOnThisDisk   = shift ;
    my $totalEntries        = shift ;
    my $centralDirSize      = shift ;
    my $centralDirOffset    = shift ;

    return  (#$offset == 0           &&
             $diskNumber == 0        &&
             $cdDiskNumber == 0      &&
             $entriesOnThisDisk == 0 &&
             $totalEntries == 0      &&
             $centralDirSize == 0    &&
             $centralDirOffset== 0
             ) ;
}

sub EndCentralHeader
{
    # APPNOTE 6.3.10, sec 4.3.16

    my $signature = shift ;
    my $data = shift ;
    my $startRecordOffset = shift ;

    print "\n";
    out $data, "END CENTRAL HEADER", Value_V($signature);

    need 18, Signatures::name($signature);

    # TODO - check values for traces of multi-part + crazy values
    my $diskNumber          = out_v "Number of this disk";
    my $cdDiskNumber        = out_v "Central Dir Disk no";
    my $entriesOnThisDisk   = out_v "Entries in this disk";
    my $totalEntries        = out_v "Total Entries";
    my $centralDirSize      = out_V "Size of Central Dir";

    my ($d, $centralDirOffset) = read_V();
    my $out = Value_V($centralDirOffset);
    testPossiblePrefix($centralDirOffset, ZIP_CENTRAL_HDR_SIG);

    $out .= " [Actual Offset is " . Value_V($centralDirOffset + $PREFIX_DELTA) . "]"
        if $PREFIX_DELTA  && $centralDirOffset != MAX32 ;
    out $d, "Offset to Central Dir", $out;

    my $comment_length = out_v "Comment Length";

    if ($comment_length)
    {
        my $here = $FH->tell() ;
        my $available = $FILELEN - $here ;
        if ($available < $comment_length)
        {
            error $here,
                  "file truncated while reading 'Comment' field in '" . Signatures::name($signature) . "'",
                  expectedMessage($comment_length, $available);
            $comment_length = $available;
        }

        if ($comment_length)
        {
            my $comment ;
            myRead($comment, $comment_length);
            outputFilename $comment, 0, "Comment";
        }
    }

    if ( ! Nesting::isNested($startRecordOffset, $FH->tell()  -1))
    {
        # Not nested
        if (! needZip64EOCDLocator($diskNumber, $cdDiskNumber, $entriesOnThisDisk, $totalEntries,  $centralDirSize, $centralDirOffset) &&
            ! emptyArchive($startRecordOffset, $diskNumber, $cdDiskNumber, $entriesOnThisDisk, $totalEntries,  $centralDirSize, $centralDirOffset))
        {
            my $commonMessage = "'Offset to Central Directory' field in '"  . Signatures::name($signature) .  "' is invalid";
            $centralDirOffset = checkOffsetValue($centralDirOffset, $startRecordOffset, $centralDirSize, $commonMessage, $startRecordOffset + 16, ZIP_CENTRAL_HDR_SIG) ;
        }
    }
    # else do nothing

    return {};
}

sub DataDescriptor
{

    # Data header record or Spanned archive marker.
    #

    # ZIP_DATA_HDR_SIG at start of file flags a spanned zip file.
    # If it is a true marker, the next four bytes MUST be a ZIP_LOCAL_HDR_SIG
    # See APPNOTE 6.3.10, sec 8.5.3, 8.5.4 & 8.5.5

    # If not at start of file, assume a Data Header Record
    # See APPNOTE 6.3.10, sec 4.3.9 & 4.3.9.3

    my $signature = shift ;
    my $data = shift ;
    my $startRecordOffset = shift ;

    my $here = $FH->tell();

    if ($here == 4)
    {
        # Spanned Archive Marker
        out $data, "SPLIT ARCHIVE MULTI-SEGMENT MARKER", Value_V($signature);
        return;

        # my (undef, $next_sig) = read_V();
        # seekTo(0);

        # if ($next_sig == ZIP_LOCAL_HDR_SIG)
        # {
        #     print "\n";
        #     out $data, "SPLIT ARCHIVE MULTI-SEGMENT MARKER", Value_V($signature);
        #     seekTo($here);
        #     return;
        # }
    }

    my $sigName = Signatures::titleName(ZIP_DATA_HDR_SIG);

    print "\n";
    out $data, $sigName, Value_V($signature);

    need  24, Signatures::name($signature);

    # Ignore header payload if nested (assume 64-bit descriptor)
    if (Nesting::isNested( $here - 4, $here - 4 + 24 - 1))
    {
        out "",  "Skipping Nested Payload";
        return {};
    }

    my $compressedSize;
    my $uncompressedSize;

    my $localEntry = $LocalDirectory->lastStreamedEntryAdded();
    my $centralEntry =  $localEntry && $localEntry->getCdEntry ;

    if (!$localEntry)
    {
        # found a Data Descriptor without a local header
        out "",  "Skipping Data Descriptor", "No matching Local header with streaming bit set";
        error $here - 4, "Orphan '$sigName' found", "No matching Local header with streaming bit set";
        return {};
    }

    my $crc = out_V "CRC";
    my $payloadLength = $here - 4 - $localEntry->payloadOffset;

    my $deltaToNext = deltaToNextSignature();
    my $cl32 = unpack "V",  peekAtOffset($here + 4, 4);
    my $cl64 = unpack "Q<", peekAtOffset($here + 4, 8);

    # use delta to next header & payload length
    # deals with use case where the payload length < 32 bit
    # will use a 32-bit value rather than the 64-bit value

    # see if delta & payload size match
    if ($deltaToNext == 16 && $cl64 == $payloadLength)
    {
        if (! $localEntry->zip64 && ($centralEntry && ! $centralEntry->zip64))
        {
            error $here, "'$sigName': expected 32-bit values, got 64-bit";
        }

        $compressedSize   = out_Q "Compressed Size" ;
        $uncompressedSize = out_Q "Uncompressed Size" ;
    }
    elsif ($deltaToNext == 8 && $cl32 == $payloadLength)
    {
        if ($localEntry->zip64)
        {
            error $here, "'$sigName': expected 64-bit values, got 32-bit";
        }

        $compressedSize   = out_V "Compressed Size" ;
        $uncompressedSize = out_V "Uncompressed Size" ;
    }

    # Try matching juast payload lengths
    elsif ($cl32 == $payloadLength)
    {
        if ($localEntry->zip64)
        {
            error $here, "'$sigName': expected 64-bit values, got 32-bit";
        }

        $compressedSize   = out_V "Compressed Size" ;
        $uncompressedSize = out_V "Uncompressed Size" ;

        warning $here, "'$sigName': Zip Header not directly after Data Descriptor";
    }
    elsif ($cl64 == $payloadLength)
    {
        if (! $localEntry->zip64 && ($centralEntry && ! $centralEntry->zip64))
        {
            error $here, "'$sigName': expected 32-bit values, got 64-bit";
        }

        $compressedSize   = out_Q "Compressed Size" ;
        $uncompressedSize = out_Q "Uncompressed Size" ;

        warning $here, "'$sigName': Zip Header not directly after Data Descriptor";
    }

    # payloads don't match, so try delta
    elsif ($deltaToNext == 16)
    {
        if (! $localEntry->zip64 && ($centralEntry && ! $centralEntry->zip64))
        {
            error $here, "'$sigName': expected 32-bit values, got 64-bit";
        }

        $compressedSize   = out_Q "Compressed Size" ;
        # compressed size is wrong
        error $here, "'$sigName': Compressed size" . decimalHex0x($compressedSize) . " doesn't match with payload size " . decimalHex0x($payloadLength);

        $uncompressedSize = out_Q "Uncompressed Size" ;
    }
    elsif ($deltaToNext == 8 )
    {
        if ($localEntry->zip64)
        {
            error $here, "'$sigName': expected 64-bit values, got 32-bit";
        }

        $compressedSize   = out_V "Compressed Size" ;
        # compressed size is wrong
        error $here, "'$sigName': Compressed Size " . decimalHex0x($compressedSize) . " doesn't match with payload size " . decimalHex0x($payloadLength);

        $uncompressedSize = out_V "Uncompressed Size" ;
    }

    # no payoad or delta match at all, so likely a false positive or data corruption
    else
    {
        warning $here, "Cannot determine size of Data Descriptor record";
    }

    # TODO - neither payload size or delta to next signature match

    if ($localEntry)
    {
        $localEntry->readDataDescriptor(1) ;
        $localEntry->crc32($crc) ;
        $localEntry->compressedSize($compressedSize) ;
        $localEntry->uncompressedSize($uncompressedSize) ;
    }

    # APPNOTE 6.3.10, sec 4.3.8
    my $filename = $localEntry->filename;
    warning undef, "Directory '$filename' must not have a payload"
        if  $filename =~ m#/$# && $uncompressedSize ;

    return {
        crc => $crc,
        compressedSize => $compressedSize,
        uncompressedSize => $uncompressedSize,
    };
}

sub SingleSegmentMarker
{
    # ZIP_SINGLE_SEGMENT_MARKER at start of file flags a spanned zip file.
    # If this ia a true marker, the next four bytes MUST be a ZIP_LOCAL_HDR_SIG
    # See APPNOTE 6.3.10, sec 8.5.3, 8.5.4 & 8.5.5

    my $signature = shift ;
    my $data = shift ;
    my $startRecordOffset = shift ;

    my $here = $FH->tell();

    if ($here == 4)
    {
        my (undef, $next_sig) = read_V();
        if ($next_sig == ZIP_LOCAL_HDR_SIG)
        {
            print "\n";
            out $data, "SPLIT ARCHIVE SINGLE-SEGMENT MARKER", Value_V($signature);
        }
        seekTo($here);
    }

    return {};
}

sub ArchiveExtraDataRecord
{
    # TODO - not seen an example of this record

    # APPNOTE 6.3.10, sec 4.3.11

    my $signature = shift ;
    my $data = shift ;
    my $startRecordOffset = shift ;

    out $data, "ARCHIVE EXTRA DATA RECORD", Value_V($signature);

    need 2, Signatures::name($signature);

    my $size = out_v "Size of record";

    need $size, Signatures::name($signature);

    outHexdump($size, "Field data", 1);

    return {};
}

sub DigitalSignature
{
    my $signature = shift ;
    my $data = shift ;
    my $startRecordOffset = shift ;

    print "\n";
    out $data, "DIGITAL SIGNATURE RECORD", Value_V($signature);

    need 2, Signatures::name($signature);
    my $Size = out_v "Size of record";

    need $Size, Signatures::name($signature);


    myRead(my $payload, $Size);
    out $payload, "Signature", hexDump16($payload);

    return {};
}

sub GeneralPurposeBits
{
    my $method = shift;
    my $gp = shift;

    out1 "[Bit  0]", "1 'Encryption'" if $gp & ZIP_GP_FLAG_ENCRYPTED_MASK;

    my %lookup = (
        0 =>    "Normal Compression",
        1 =>    "Maximum Compression",
        2 =>    "Fast Compression",
        3 =>    "Super Fast Compression");


    if ($method == ZIP_CM_DEFLATE)
    {
        my $mid = ($gp >> 1) & 0x03 ;

        out1 "[Bits 1-2]", "$mid '$lookup{$mid}'";
    }

    if ($method == ZIP_CM_LZMA)
    {
        if ($gp & ZIP_GP_FLAG_LZMA_EOS_PRESENT) {
            out1 "[Bit 1]", "1 'LZMA EOS Marker Present'" ;
        }
        else {
            out1 "[Bit 1]", "0 'LZMA EOS Marker Not Present'" ;
        }
    }

    if ($method == ZIP_CM_IMPLODE) # Imploding
    {
        out1 "[Bit 1]", ($gp & (1 << 1) ? "1 '8k" : "0 '4k") . " Sliding Dictionary'" ;
        out1 "[Bit 2]", ($gp & (2 << 1) ? "1 '3" : "0 '2"  ) . " Shannon-Fano Trees'" ;
    }

    out1 "[Bit  3]", "1 'Streamed'"           if $gp & ZIP_GP_FLAG_STREAMING_MASK;
    out1 "[Bit  4]", "1 'Enhanced Deflating'" if $gp & 1 << 4;
    out1 "[Bit  5]", "1 'Compressed Patched'" if $gp & ZIP_GP_FLAG_PATCHED_MASK ;
    out1 "[Bit  6]", "1 'Strong Encryption'"  if $gp & ZIP_GP_FLAG_STRONG_ENCRYPTED_MASK;
    out1 "[Bit 11]", "1 'Language Encoding'"  if $gp & ZIP_GP_FLAG_LANGUAGE_ENCODING;
    out1 "[Bit 12]", "1 'Pkware Enhanced Compression'"  if $gp & ZIP_GP_FLAG_PKWARE_ENHANCED_COMP ;
    out1 "[Bit 13]", "1 'Encrypted Central Dir'"  if $gp & ZIP_GP_FLAG_ENCRYPTED_CD ;

    return ();
}


sub seekSet
{
    my $fh = $_[0] ;
    my $size = $_[1];

    use Fcntl qw(SEEK_SET);
    seek($fh, $size, SEEK_SET);

}

sub skip
{
    my $fh = $_[0] ;
    my $size = $_[1];

    use Fcntl qw(SEEK_CUR);
    seek($fh, $size, SEEK_CUR);

}


sub myRead
{
    my $got = \$_[0] ;
    my $size = $_[1];

    my $wantSize = $size;
    $$got = '';

    if ($size == 0)
    {
        return ;
    }

    if ($size > 0)
    {
        my $buff ;
        my $status = $FH->read($buff, $size);
        return $status
            if $status < 0;
        $$got .= $buff ;
    }

    my $len = length $$got;
    # fatal undef, "Truncated file (got $len, wanted $wantSize): $!"
    fatal undef, "Unexpected zip file truncation",
                expectedMessage($wantSize, $len)
        if length $$got != $wantSize;
}

sub expectedMessage
{
    my $expected = shift;
    my $got = shift;
    return "Expected " . decimalHex0x($expected) . " bytes, but only " . decimalHex0x($got) . " available"
}

sub need
{
    my $byteCount = shift ;
    my $message = shift ;
    my $field = shift // '';

    # return $FILELEN - $FH->tell() >= $byteCount;
    my $here = $FH->tell() ;
    my $available = $FILELEN - $here ;
    if ($available < $byteCount)
    {
        my @message ;

        if ($field)
        {
            push @message, "Unexpected zip file truncation while reading '$field' field in '$message'";
        }
        else
        {
            push @message, "Unexpected zip file truncation while reading '$message'";
        }


        push @message, expectedMessage($byteCount, $available);
        # push @message, sprintf("Expected 0x%X bytes, but only 0x%X available", $byteCount, $available);
        push @message, "Try running with --walk' or '--scan' options"
            if ! $opt_scan && ! $opt_walk ;

        fatal $here, @message;
    }
}

sub testPossiblePrefix
{
    my $offset = shift;
    my $expectedSignature = shift ;

    if (testPossiblePrefixNoPREFIX_DELTA($offset, $expectedSignature))
    {
        $PREFIX_DELTA = $POSSIBLE_PREFIX_DELTA;
        $POSSIBLE_PREFIX_DELTA = 0;

        reportPrefixData();

        return 1
    }

    return 0
}

sub testPossiblePrefixNoPREFIX_DELTA
{
    my $offset = shift;
    my $expectedSignature = shift ;

    return 0
        if $offset + 4 > $FILELEN || ! $POSSIBLE_PREFIX_DELTA || $PREFIX_DELTA;

    my $currentOFFSET = $OFFSET;
    my $gotSig = readSignatureFromOffset($offset);

    if ($gotSig == $expectedSignature)
    {
        # do have possible prefix data, but the offset is correct
        $POSSIBLE_PREFIX_DELTA = $PREFIX_DELTA = 0;
        $OFFSET = $currentOFFSET;

        return 0;
    }

    $gotSig = readSignatureFromOffset($offset + $POSSIBLE_PREFIX_DELTA);

    $OFFSET = $currentOFFSET;

    return  ($gotSig == $expectedSignature) ;
}

sub offsetIsValid
{
    my $offset = shift;
    my $headerStart = shift;
    my $centralDirSize = shift;
    my $commonMessage = shift ;
    my $expectedSignature = shift ;
    my $dereferencePointer = shift;

    my $must_point_back = 1;

    my $delta = $offset - $FILELEN + 1 ;

    $offset += $PREFIX_DELTA
        if $PREFIX_DELTA ;

    return sprintf("value %s is %s bytes past EOF", decimalHex0x($offset), decimalHex0x($delta))
        if $delta > 0 ;

    return sprintf "value %s must be less that %s", decimalHex0x($offset), decimalHex0x($headerStart)
        if $must_point_back && $offset >= $headerStart;

    if ($dereferencePointer)
    {
        my $actual = $headerStart - $centralDirSize;
        my $cdSizeOK = ($actual == $offset);
        my $possibleDelta = $actual - $offset;

        if ($centralDirSize && ! $cdSizeOK && $possibleDelta > 0 && readSignatureFromOffset($possibleDelta) == ZIP_LOCAL_HDR_SIG)
        {
            # If testing end of central dir, check if the location of the first CD header
            # is consistent with the central dir size.
            # Common use case is a SFX zip file

            my $gotSig = readSignatureFromOffset($actual);
            my $v = hexValue32($gotSig);
            return 'value @ ' .  hexValue($actual) . " should decode to signature for " . Signatures::nameAndHex($expectedSignature) . ". Got $v" # . hexValue32($gotSig)
                if $gotSig != $expectedSignature ;

            $PREFIX_DELTA = $possibleDelta;
            reportPrefixData();

            return undef;
        }
        else
        {
            my $gotSig = readSignatureFromOffset($offset);
            my $v = hexValue32($gotSig);
            return 'value @ ' .  hexValue($offset) . " should decode to signature for " . Signatures::nameAndHex($expectedSignature) . ". Got $v" # . hexValue32($gotSig)
                if $gotSig != $expectedSignature ;
        }
    }

    return undef ;
}

sub checkOffsetValue
{
    my $offset = shift;
    my $headerStart = shift;
    my $centralDirSize = shift;
    my $commonMessage = shift ;
    my $messageOffset = shift;
    my $expectedSignature = shift ;
    my $fatal = shift // 0;
    my $dereferencePointer = shift // 1;

    my $keepOFFSET = $OFFSET ;

    my $message = offsetIsValid($offset, $headerStart, $centralDirSize, $commonMessage, $expectedSignature, $dereferencePointer);
    if ($message)
    {
        fatal_tryWalk($messageOffset, $commonMessage, $message)
            if $fatal;

        error $messageOffset, $commonMessage, $message
            if ! $fatal;
    }

    $OFFSET = $keepOFFSET;

    return $offset + $PREFIX_DELTA;

}

sub fatal_tryWalk
{
    my $offset   = shift ;
    my $message = shift;

    fatal($offset, $message, @_, "Try running with --walk' or '--scan' options");
}

sub fatal
{
    my $offset   = shift ;
    my $message = shift;

    return if $fatalDisabled;

    if (defined $offset)
    {
        warn "#\n# FATAL: Offset " . hexValue($offset) . ": $message\n";
    }
    else
    {
        warn "#\n# FATAL: $message\n";
    }

    warn  "#        $_ . \n"
        for @_;
    warn "#\n" ;

    exit 1;
}

sub disableFatal
{
    $fatalDisabled = 1 ;
}

sub enableFatal
{
    $fatalDisabled = 0 ;
}

sub topLevelFatal
{
    my $message = shift ;

    no warnings 'utf8';

    warn "FATAL: $message\n";

    warn  "$_ . \n"
        for @_;

    exit 1;
}

sub internalFatal
{
    my $offset   = shift ;
    my $message = shift;

    no warnings 'utf8';

    if (defined $offset)
    {
        warn "# FATAL: Offset " . hexValue($offset) . ": Internal Error: $message\n";
    }
    else
    {
        warn "# FATAL: Internal Error: $message\n";
    }

    warn "#        $_ \n"
        for @_;

    warn "#        Please report error at https://github.com/pmqs/zipdetails/issues\n";
    exit 1;
}

sub warning
{
    my $offset   = shift ;
    my $message  = shift;

    no warnings 'utf8';

    return
        unless $opt_want_warning_mesages ;

    say "#"
        unless $lastWasMessage ++ ;

    if (defined $offset)
    {
        say "# WARNING: Offset " . hexValue($offset) . ": $message";
    }
    else
    {
        say "# WARNING: $message";
    }


    say "#          $_" for @_ ;
    say "#";
    ++ $WarningCount ;

    $exit_status_code |= 2
        if $opt_want_message_exit_status ;
}

sub error
{
    my $offset   = shift ;
    my $message  = shift;

    no warnings 'utf8';

    return
        unless $opt_want_error_mesages ;

    say "#"
        unless $lastWasMessage ++ ;

    if (defined $offset)
    {
        say "# ERROR: Offset " . hexValue($offset) . ": $message";
    }
    else
    {
        say "# ERROR: $message";
    }


    say "#        $_" for @_ ;
    say "#";

    ++ $ErrorCount ;

    $exit_status_code |= 4
        if $opt_want_message_exit_status ;
}

sub debug
{
    my $offset   = shift ;
    my $message  = shift;

    no warnings 'utf8';

    say "#"
        unless $lastWasMessage ++ ;

    if (defined $offset)
    {
        say "# DEBUG: Offset " . hexValue($offset) . ": $message";
    }
    else
    {
        say "# DEBUG: $message";
    }


    say "#        $_" for @_ ;
    say "#";
}

sub internalError
{
    my $message  = shift;

    no warnings 'utf8';

    say "#";
    say "# ERROR: $message";
    say "#        $_" for @_ ;
    say "#        Please report error at https://github.com/pmqs/zipdetails/issues";
    say "#";

    ++ $ErrorCount ;
}

sub reportPrefixData
{
    my $delta = shift // $PREFIX_DELTA ;
    state $reported = 0;
    return if $reported || $delta == 0;

    info 0, "found " . decimalHex0x($delta) . " bytes before beginning of zipfile" ;
    $reported = 1;
}

sub info
{
    my $offset   = shift;
    my $message  = shift;

    no warnings 'utf8';

    return
        unless $opt_want_info_mesages ;

    say "#"
        unless $lastWasMessage ++ ;

    if (defined $offset)
    {
        say "# INFO: Offset " . hexValue($offset) . ": $message";
    }
    else
    {
        say "# INFO: $message";
    }

    say "#       $_" for @_ ;
    say "#";

    ++ $InfoCount ;

    $exit_status_code |= 1
        if $opt_want_message_exit_status ;
}

sub walkExtra
{
    # APPNOTE 6.3.10, sec 4.4.11, 4.4.28, 4.5
    my $XLEN = shift;
    my $entry = shift;

    # Caller has determined that there are $XLEN bytes available to read

    my $buff ;
    my $offset = 0 ;

    my $id;
    my $subLen;
    my $payload ;

    my $count = 0 ;
    my $endExtraOffset = $FH->tell() + $XLEN ;

    while ($offset < $XLEN) {

        ++ $count;

        # Detect if there is not enough data for an extra ID and length.
        # Android zipalign and zipflinger are prime candidates for these
        # non-standard extra sub-fields.
        my $remaining = $XLEN - $offset;
        if ($remaining < ZIP_EXTRA_SUBFIELD_HEADER_SIZE) {
            # There is not enough left.
            # Consume whatever is there and return so parsing
            # can continue.

            myRead($payload, $remaining);
            my $data = hexDump($payload);

            if ($payload =~ /^\x00+$/)
            {
                # All nulls
                out $payload, "Null Padding in Extra";
                info $FH->tell() - length($payload), decimalHex0x(length $payload) . " Null Padding Bytes in Extra Field" ;
            }
            else
            {
                out $payload, "Extra Data", $data;
                error $FH->tell() - length($payload), "'Extra Data' Malformed";
            }

            return undef;
        }

        myRead($id, ZIP_EXTRA_SUBFIELD_ID_SIZE);
        $offset += ZIP_EXTRA_SUBFIELD_ID_SIZE;
        my $lookID = unpack "v", $id ;
        if ($lookID == 0)
        {
            # check for null padding at end of extra
            my $here = $FH->tell();
            my $rest;
            myRead($rest, $XLEN - $offset);
            if ($rest =~ /^\x00+$/)
            {
                my $len = length ($id . $rest) ;
                out $id . $rest, "Null Padding in Extra";
                info $FH->tell() - $len, decimalHex0x($len) . " Null Padding Bytes in Extra Field";
                return undef;
            }

            seekTo($here);
        }

        my ($who, $decoder, $local_min, $local_max, $central_min, $central_max) =  @{ $Extras{$lookID} // ['', undef, undef,  undef,  undef, undef ] };

        my $idString =  Value_v($lookID) ;
        $idString .=  " '$who'"
            if $who;

        out $id, "Extra ID #$count", $idString ;
        info $FH->tell() - 2, "Unknown Extra ID $idString"
            if ! exists $Extras{$lookID} ;

        myRead($buff, ZIP_EXTRA_SUBFIELD_LEN_SIZE);
        $offset += ZIP_EXTRA_SUBFIELD_LEN_SIZE;

        $subLen =  unpack("v", $buff);
        out2 $buff, "Length", Value_v($subLen) ;

        $remaining = $XLEN - $offset;
        if ($subLen > $remaining )
        {
            error $FH->tell() -2,
                  extraFieldIdentifier($lookID) . ": 'Length' field invalid",
                  sprintf("value %s > %s bytes remaining", decimalHex0x($subLen), decimalHex0x($remaining));
            outSomeData $remaining, "  Extra Payload";
            return undef;
        }

        if (! defined $decoder)
        {
            if ($subLen)
            {
                myRead($payload, $subLen);
                my $data = hexDump16($payload);

                out2 $payload, "Extra Payload", $data;
            }
        }
        else
        {
            if (testExtraLimits($lookID, $subLen, $entry->inCentralDir))
            {
                my $endExtraOffset = $FH->tell() + $subLen;
                $decoder->($lookID, $subLen, $entry) ;

                # Belt & Braces - should now be at $endExtraOffset
                # error here means issue in an extra handler
                # should noy happen, but just in case
                # TODO -- need tests for this
                my $here = $FH->tell() ;
                if ($here > $endExtraOffset)
                {
                    # gone too far, so need to bomb out now
                    internalFatal $here, "Overflow processing " . extraFieldIdentifier($lookID) . ".",
                                  sprintf("Should be at offset %s, actually at %s", decimalHex0x($endExtraOffset),  decimalHex0x($here));
                }
                elsif ($here < $endExtraOffset)
                {
                    # not gone far enough, can recover
                    error $here,
                            sprintf("Expected to be at offset %s after processing %s, actually at %s", decimalHex0x($endExtraOffset),  extraFieldIdentifier($lookID), decimalHex0x($here)),
                            "Skipping " . decimalHex0x($endExtraOffset - $here) . " bytes";
                    outSomeData $endExtraOffset - $here, "  Extra Data";
                }
            }
        }

        $offset += $subLen ;
    }

    return undef ;
}

sub testExtraLimits
{
    my $lookID = shift;
    my $size = shift;
    my $inCentralDir = shift;

    my ($who, undef, $local_min, $local_max, $central_min, $central_max) =  @{ $Extras{$lookID} // ['', undef, undef,  undef,  undef, undef ] };

    my ($min, $max) = $inCentralDir
                        ? ($central_min, $central_max)
                        : ($local_min, $local_max) ;

    return 1
        if ! defined $min && ! defined $max ;

    if (defined $min && defined $max)
    {
        # both the same
        if ($min == $max)
        {
            if ($size != $min)
            {
                error $FH->tell() -2, sprintf "%s: 'Length' field invalid: expected %s, got %s", extraFieldIdentifier($lookID), decimalHex0x($min),  decimalHex0x($size);
                outSomeData $size, "  Extra Payload" if $size;
                return 0;
            }
        }
        else # min != max
        {
            if ($size < $min || $size > $max)
            {
                error $FH->tell() -2, sprintf "%s: 'Length' field invalid: value must be betweem %s and %s, got %s", extraFieldIdentifier($lookID), decimalHex0x($min), decimalHex0x($max), decimalHex0x($size);
                outSomeData $size, "  Extra Payload" if $size ;
                return 0;
            }
        }

    }
    else # must be defined $min & undefined max
    {
        if ($size < $min)
        {
            error $FH->tell() -2, sprintf "%s: 'Length' field invalid: value must be at least %s, got %s", extraFieldIdentifier($lookID), decimalHex0x($min),  decimalHex0x($size);
            outSomeData $size, "  Extra Payload" if $size;
            return 0;
        }
    }

    return 1;

}

sub full32
{
    return ($_[0] // 0) == MAX32 ;
}

sub full16
{
    return ($_[0] // 0) == MAX16 ;
}

sub decode_Zip64
{
    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    myRead(my $payload, $len);
    if ($entry->inCentralDir() )
    {
        walk_Zip64_in_CD($extraID, $payload, $entry, 1) ;
    }
    else
    {
        walk_Zip64_in_LD($extraID, $payload, $entry, 1) ;

    }
}

sub walk_Zip64_in_LD
{
    my $extraID = shift ;
    my $zip64Extended = shift;
    my $entry = shift;
    my $display = shift // 1 ;

    my $fieldStart = $FH->tell() - length $zip64Extended;
    my $fieldOffset = $fieldStart ;

    $ZIP64 = 1;
    $entry->zip64(1);

    if (length $zip64Extended == 0)
    {
        info $fieldOffset, extraFieldIdentifier($extraID) .  ": Length is Zero";
        return;
    }

    my $assumeLengthsPresent   = (length($zip64Extended) == 16) ;
    my $assumeAllFieldsPresent = (length($zip64Extended) == 28) ;

    if ($assumeLengthsPresent || $assumeAllFieldsPresent || full32 $entry->std_uncompressedSize )
    {
        # TODO defer a warning if in local header & central/local don't have std_uncompressedSizeset to 0xffffffff
        if (length $zip64Extended < 8)
        {
            my $message = extraFieldIdentifier($extraID) .  ": Expected " . decimalHex0x(8) . " bytes for 'Uncompressed Size': only " . decimalHex0x(length $zip64Extended)  . " bytes present";
            error $fieldOffset, $message;
            out2 $zip64Extended, $message;
            return;
        }

        $fieldOffset += 8;
        my $data = substr($zip64Extended, 0, 8, "") ;
        $entry->uncompressedSize(unpack "Q<", $data);
        out2 $data, "Uncompressed Size", Value_Q($entry->uncompressedSize)
            if $display;
    }

    if ($assumeLengthsPresent || $assumeAllFieldsPresent || full32 $entry->std_compressedSize)
    {
        if (length $zip64Extended < 8)
        {
            my $message = extraFieldIdentifier($extraID) .  ": Expected " . decimalHex0x(8) . " bytes for 'Compressed Size': only " . decimalHex0x(length $zip64Extended)  . " bytes present";
            error $fieldOffset, $message;
            out2 $zip64Extended, $message;
            return;
        }

        $fieldOffset += 8;

        my $data = substr($zip64Extended, 0, 8, "") ;
        $entry->compressedSize( unpack "Q<", $data);
        out2 $data, "Compressed Size", Value_Q($entry->compressedSize)
            if $display;
    }

    # Zip64 in local header should not have localHeaderOffset or disk number
    # but some zip files do

    if ($assumeAllFieldsPresent)
    {
        $fieldOffset += 8;

        my $data = substr($zip64Extended, 0, 8, "") ;
        my $localHeaderOffset = unpack "Q<", $data;
        out2 $data, "Offset to Local Dir", Value_Q($localHeaderOffset)
            if $display;
    }

    if ($assumeAllFieldsPresent)
    {
        $fieldOffset += 4;

        my $data = substr($zip64Extended, 0, 4, "") ;
        my $diskNumber = unpack "v", $data;
        out2 $data, "Disk Number", Value_V($diskNumber)
            if $display;
    }

    if (length $zip64Extended)
    {
        if ($display)
        {
            out2 $zip64Extended, "Unexpected Data", hexDump16 $zip64Extended ;
            info $fieldOffset, extraFieldIdentifier($extraID) .  ": Unexpected Data: " . decimalHex0x(length $zip64Extended) . " bytes";
        }
    }

}

sub walk_Zip64_in_CD
{
    my $extraID = shift ;
    my $zip64Extended = shift;
    my $entry = shift;
    my $display = shift // 1 ;

    my $fieldStart = $FH->tell() - length $zip64Extended;
    my $fieldOffset = $fieldStart ;

    $ZIP64 = 1;
    $entry->zip64(1);

    if (length $zip64Extended == 0)
    {
        info $fieldOffset, extraFieldIdentifier($extraID) .  ": Length is Zero";
        return;
    }

    my $assumeAllFieldsPresent = (length($zip64Extended) == 28) ;

    if ($assumeAllFieldsPresent || full32 $entry->std_uncompressedSize )
    {
        if (length $zip64Extended < 8)
        {
            my $message = extraFieldIdentifier($extraID) .  ": Expected " . decimalHex0x(8) . " bytes for 'Uncompressed Size': only " . decimalHex0x(length $zip64Extended)  . " bytes present";
            error $fieldOffset, $message;
            out2 $zip64Extended, $message;
            return;
        }

        $fieldOffset += 8;
        my $data = substr($zip64Extended, 0, 8, "") ;
        $entry->uncompressedSize(unpack "Q<", $data);
        out2 $data, "Uncompressed Size", Value_Q($entry->uncompressedSize)
            if $display;
    }

    if ($assumeAllFieldsPresent || full32 $entry->std_compressedSize)
    {
        if (length $zip64Extended < 8)
        {
            my $message = extraFieldIdentifier($extraID) .  ": Expected " . decimalHex0x(8) . " bytes for 'Compressed Size': only " . decimalHex0x(length $zip64Extended)  . " bytes present";
            error $fieldOffset, $message;
            out2 $zip64Extended, $message;
            return;
        }

        $fieldOffset += 8;

        my $data = substr($zip64Extended, 0, 8, "") ;
        $entry->compressedSize(unpack "Q<", $data);
        out2 $data, "Compressed Size", Value_Q($entry->compressedSize)
            if $display;
    }

    if ($assumeAllFieldsPresent || full32 $entry->std_localHeaderOffset)
    {
        if (length $zip64Extended < 8)
        {
            my $message = extraFieldIdentifier($extraID) .  ": Expected " . decimalHex0x(8) . " bytes for 'Offset to Local Dir': only " . decimalHex0x(length $zip64Extended)  . " bytes present";
            error $fieldOffset, $message;
            out2 $zip64Extended, $message;
            return;
        }

        $fieldOffset += 8;

        my $here = $FH->tell();
        my $data = substr($zip64Extended, 0, 8, "") ;
        $entry->localHeaderOffset(unpack "Q<", $data);
        out2 $data, "Offset to Local Dir", Value_Q($entry->localHeaderOffset)
            if $display;

        my $commonMessage = "'Offset to Local Dir' field in 'Zip64 Extra Field' is invalid";
        $entry->localHeaderOffset(checkOffsetValue($entry->localHeaderOffset, $fieldStart, 0, $commonMessage, $fieldStart, ZIP_LOCAL_HDR_SIG, 0) );
    }

    if ($assumeAllFieldsPresent || full16 $entry->std_diskNumber)
    {
        if (length $zip64Extended < 4)
        {
            my $message = extraFieldIdentifier($extraID) .  ": Expected " . decimalHex0x(4) . " bytes for 'Disk Number': only " . decimalHex0x(length $zip64Extended)  . " bytes present";
            error $fieldOffset, $message;
            out2 $zip64Extended, $message;
            return;
        }

        $fieldOffset += 4;

        my $here = $FH->tell();
        my $data = substr($zip64Extended, 0, 4, "") ;
        $entry->diskNumber(unpack "v", $data);
        out2 $data, "Disk Number", Value_V($entry->diskNumber)
            if $display;
        $entry->zip64_diskNumberPresent(1);
    }

    if (length $zip64Extended)
    {
        if ($display)
        {
            out2 $zip64Extended, "Unexpected Data", hexDump16 $zip64Extended ;
            info $fieldOffset, extraFieldIdentifier($extraID) .  ": Unexpected Data: " . decimalHex0x(length $zip64Extended) . " bytes";
        }
    }
}

sub Ntfs2Unix
{
    my $m = shift;
    my $v = shift;

    # NTFS offset is 19DB1DED53E8000

    my $hex = Value_Q($v) ;

    # Treat empty value as special case
    # Could decode to 1 Jan 1601
    return "$hex 'No Date/Time'"
        if $v == 0;

    $v -= 0x19DB1DED53E8000 ;
    my $ns = ($v % 10000000) * 100;
    my $elapse = int ($v/10000000);
    return "$hex '" . getT($elapse) .
           " " . sprintf("%0dns'", $ns);
}

sub decode_NTFS_Filetimes
{
    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    out_V "  Reserved";
    out_v "  Tag1";
    out_v "  Size1" ;

    my ($m, $s1) = read_Q;
    out $m, "  Mtime", Ntfs2Unix($m, $s1);

    my ($a, $s3) = read_Q;
    out $a, "  Atime", Ntfs2Unix($a, $s3);

    my ($c, $s2) = read_Q;
    out $c, "  Ctime", Ntfs2Unix($c, $s2);
}

sub OpenVMS_DateTime
{
    my $ix = shift;
    my $tag = shift;
    my $size = shift;

    # VMS epoch is 17 Nov 1858
    # Offset to Unix Epoch is -0x7C95674C3DA5C0 (-35067168005400000)

    my ($data, $value) = read_Q();

    my $datetime = "No Date Time'";
    if ($value != 0)
    {
        my $v =  $value - 0x007C95674C3DA5C0 ;
        my $ns = ($v % 10000000) * 100 ;
        my $seconds = int($v / 10000000) ;
        $datetime = getT($seconds) .
           " " . sprintf("%0dns'", $ns);
    }

    out2 $data, "  Attribute", Value_Q($value) . " '$datetime";
}

sub OpenVMS_DumpBytes
{
    my $ix = shift;
    my $tag = shift;
    my $size = shift;

    myRead(my $data, $size);

    out($data, "    Attribute", hexDump16($data));

}

sub OpenVMS_4ByteValue
{
    my $ix = shift;
    my $tag = shift;
    my $size = shift;

    my ($data, $value) = read_V();

    out2 $data, "  Attribute", Value_V($value);
}

sub OpenVMS_UCHAR
{
    my $ix = shift;
    my $tag = shift;
    my $size = shift;

    state $FCH = {
        0     => 'FCH$M_WASCONTIG',
        1     => 'FCH$M_NOBACKUP',
        2     => 'FCH$M_WRITEBACK',
        3     => 'FCH$M_READCHECK',
        4     => 'FCH$M_WRITCHECK',
        5     => 'FCH$M_CONTIGB',
        6     => 'FCH$M_LOCKED',
        6     => 'FCH$M_CONTIG',
        11    => 'FCH$M_BADACL',
        12    => 'FCH$M_SPOOL',
        13    => 'FCH$M_DIRECTORY',
        14    => 'FCH$M_BADBLOCK',
        15    => 'FCH$M_MARKDEL',
        16    => 'FCH$M_NOCHARGE',
        17    => 'FCH$M_ERASE',
        18    => 'FCH$M_SHELVED',
        20    => 'FCH$M_SCRATCH',
        21    => 'FCH$M_NOMOVE',
        22    => 'FCH$M_NOSHELVABLE',
    } ;

    my ($data, $value) = read_V();

    out2 $data, "  Attribute", Value_V($value);

    for my $bit ( sort { $a <=> $b } keys %{ $FCH } )
    {
        # print "$bit\n";
        if ($value & (1 << $bit) )
        {
            out1 "      [Bit $bit]", $FCH->{$bit} ;
        }
    }
}

sub OpenVMS_2ByteValue
{
    my $ix = shift;
    my $tag = shift;
    my $size = shift;

    my ($data, $value) = read_v();

    out2 $data, "  Attribute", Value_v($value);
}

sub OpenVMS_revision
{
    my $ix = shift;
    my $tag = shift;
    my $size = shift;

    my ($data, $value) = read_v();

    out2 $data, "  Attribute", Value_v($value) . "'Revision Count " . Value_v($value) . "'";
}

sub decode_OpenVMS
{
    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    state $openVMS_tags = {
        0x04    => [ 'ATR$C_RECATTR',   \&OpenVMS_DumpBytes  ],
        0x03    => [ 'ATR$C_UCHAR',     \&OpenVMS_UCHAR      ],
        0x11    => [ 'ATR$C_CREDATE',   \&OpenVMS_DateTime   ],
        0x12    => [ 'ATR$C_REVDATE',   \&OpenVMS_DateTime   ],
        0x13    => [ 'ATR$C_EXPDATE',   \&OpenVMS_DateTime   ],
        0x14    => [ 'ATR$C_BAKDATE',   \&OpenVMS_DateTime   ],
        0x0D    => [ 'ATR$C_ASCDATES',  \&OpenVMS_revision   ],
        0x15    => [ 'ATR$C_UIC',       \&OpenVMS_4ByteValue ],
        0x16    => [ 'ATR$C_FPRO',      \&OpenVMS_DumpBytes  ],
        0x17    => [ 'ATR$C_RPRO',      \&OpenVMS_2ByteValue ],
        0x1D    => [ 'ATR$C_JOURNAL',   \&OpenVMS_DumpBytes  ],
        0x1F    => [ 'ATR$C_ADDACLENT', \&OpenVMS_DumpBytes  ],
    } ;

    out_V "  CRC";
    $len -= 4;

    my $ix = 1;
    while ($len)
    {
        my ($data, $tag) = read_v();
        my $tagname = 'Unknown Tag';
        my $decoder = undef;

        if ($openVMS_tags->{$tag})
        {
            ($tagname, $decoder) = @{ $openVMS_tags->{$tag} } ;
        }

        out2 $data,  "Tag #$ix", Value_v($tag) . " '" . $tagname . "'" ;
        my $size = out_v "    Size";

        if (defined $decoder)
        {
            $decoder->($ix, $tag, $size) ;
        }
        else
        {
            outSomeData($size, "    Attribute");
        }

        ++ $ix;
        $len -= $size + 2 + 2;
    }

}

sub getT
{
    my $time = shift ;

    if ($opt_utc)
     { return scalar gmtime($time) // 'Unknown'}
    else
     { return scalar localtime($time) // 'Unknown' }
}

sub getTime
{
    my $time = shift ;

    return "'Invalid Date or Time'"
        if ! defined $time;

    return "'" . getT($time) . "'";
}

sub LastModTime
{
    my $value = shift ;

    return "'No Date/Time'"
        if $value == 0;

    return getTime(_dosToUnixTime($value))
}

sub _dosToUnixTime
{
    my $dt = shift;

    # Mozilla xpi files have empty datetime
    # This is not a valid Dos datetime value
    return 0 if $dt == 0 ;

    my $year = ( ( $dt >> 25 ) & 0x7f ) + 80;
    my $mon  = ( ( $dt >> 21 ) & 0x0f ) - 1;
    my $mday = ( ( $dt >> 16 ) & 0x1f );

    my $hour = ( ( $dt >> 11 ) & 0x1f );
    my $min  = ( ( $dt >> 5  ) & 0x3f );
    my $sec  = ( ( $dt << 1  ) & 0x3e );

    use Time::Local ;
    my $time_t;
    eval
    {
        # Use eval to catch crazy dates
        $time_t = Time::Local::timegm( $sec, $min, $hour, $mday, $mon, $year);
    }
    or do
    {
        my $dosDecode = $year+1900 . sprintf "-%02u-%02u %02u:%02u:%02u", $mon, $mday, $hour, $min, $sec;
        warning $FH->tell(), "'Modification Time' value " . decimalHex0x($dt, 4) .  "  decodes to '$dosDecode': not a valid DOS date/time" ;
        return undef
    };

    return $time_t;

}

sub decode_UT
{
    # 0x5455 'UT: Extended Timestamp'

    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    # Definition in IZ APPNOTE

    # NOTE: Although the IZ appnote says that the central directory
    #       doesn't store the Acces & Creation times, there are
    #       some implementations that do poopulate the CD incorrectly.

    # Caller has determined that at least one byte is available

    # When $full is true assume all timestamps are present
    my $full = ($len == 13) ;

    my $remaining = $len;

    my ($data, $flags) = read_C();

    my $v = Value_C $flags;
    my @f ;
    push @f, "Modification"    if $flags & 1;
    push @f, "Access" if $flags & 2;
    push @f, "Creation" if $flags & 4;
    $v .= " '" . join(' ', @f) . "'"
        if @f;

    out $data, "  Flags", $v;

    info $FH->tell() - 1, extraFieldIdentifier($extraID) . ": Reserved bits set in 'Flags' field"
        if $flags & ~0x7;

    -- $remaining;

    if ($flags & 1 || $full)
    {
        if ($remaining == 0 )
        {
            # Central Dir only has Modification Time
            error $FH->tell(), extraFieldIdentifier($extraID) . ": Missing field 'Modification Time'" ;
            return;
        }
        else
        {
            info $FH->tell(), extraFieldIdentifier($extraID) .  ": Unexpected 'Modification Time' present"
                if ! ($flags & 1)  ;

            if ($remaining < 4)
            {
                outSomeData $remaining, "  Extra Data";
                error $FH->tell() - $remaining,
                    extraFieldIdentifier($extraID) .  ": Truncated reading 'Modification Time'",
                    expectedMessage(4, $remaining);
                return;
            }

            my ($data, $time) = read_V();

            out2 $data, "Modification Time",    Value_V($time) . " " . getTime($time) ;

            $remaining -= 4 ;
        }
    }

    # The remaining sub-fields are only present in the Local Header

    if ($flags & 2 || $full)
    {
        if ($remaining == 0 && $entry->inCentralDir)
        {
            # Central Dir doesn't have access time
        }
        else
        {
            info $FH->tell(), extraFieldIdentifier($extraID) . ": Unexpected 'Access Time' present"
                if ! ($flags & 2) || $entry->inCentralDir ;

            if ($remaining < 4)
            {
                outSomeData $remaining, "  Extra Data";
                error $FH->tell() - $remaining,
                    extraFieldIdentifier($extraID) . ": Truncated reading 'Access Time'" ,
                    expectedMessage(4, $remaining);

                return;
            }

            my ($data, $time) = read_V();

            out2 $data, "Access Time",    Value_V($time) . " " . getTime($time) ;
            $remaining -= 4 ;
        }
    }

    if ($flags & 4  || $full)
    {
        if ($remaining == 0 && $entry->inCentralDir)
        {
            # Central Dir doesn't have creation time
        }
        else
        {
            info $FH->tell(), extraFieldIdentifier($extraID) . ": Unexpected 'Creation Time' present"
                if ! ($flags & 4) || $entry->inCentralDir ;

            if ($remaining < 4)
            {
                outSomeData $remaining, "  Extra Data";

                error  $FH->tell() - $remaining,
                    extraFieldIdentifier($extraID) . ": Truncated reading 'Creation Time'" ,
                    expectedMessage(4, $remaining);

                return;
            }

            my ($data, $time) = read_V();

            out2 $data, "Creation Time",    Value_V($time) . " " . getTime($time) ;
        }
    }
}


sub decode_Minizip_Signature
{
    # 0x10c5 Minizip CMS Signature

    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    # Definition in https://github.com/zlib-ng/minizip-ng/blob/master/doc/mz_extrafield.md#cms-signature-0x10c5

    $CentralDirectory->setMiniZipEncrypted();

    if ($len == 0)
    {
        info $FH->tell() - 2, extraFieldIdentifier($extraID) . ": Zero length Signature";
        return;
    }

    outHexdump($len, "  Signature");

}

sub decode_Minizip_Hash
{
    # 0x1a51 Minizip Hash
    # Definition in https://github.com/zlib-ng/minizip-ng/blob/master/doc/mz_extrafield.md#hash-0x1a51

    # caller ckecks there are at least 4 bytes available
    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    state $Algorithm = {
            10 => 'MD5',
            20 => 'SHA1',
            23 => 'SHA256',
    };

    my $remaining = $len;

    $CentralDirectory->setMiniZipEncrypted();

    my ($data, $alg) = read_v();
    my $algorithm = $Algorithm->{$alg} // "Unknown";

    out $data, "  Algorithm", Value_v($alg) . " '$algorithm'";
    if (! exists $Algorithm->{$alg})
    {
        info $FH->tell() - 2, extraFieldIdentifier($extraID) . ": Unknown algorithm ID " .Value_v($alg);
    }

    my ($d, $digestSize) = read_v();
    out $d, "  Digest Size", Value_v($digestSize);

    $remaining -= 4;

    if ($digestSize == 0)
    {
        info $FH->tell() - 2, extraFieldIdentifier($extraID) . ": Zero length Digest";
    }
    elsif ($digestSize > $remaining)
    {
        error $FH->tell() - 2, extraFieldIdentifier($extraID) . ": Digest Size " . decimalHex0x($digestSize) . " >  " . decimalHex0x($remaining) . " bytes remaining in extra field" ;
        $digestSize = $remaining ;
    }

    outHexdump($digestSize, "  Digest");

    $remaining -= $digestSize;

    if ($remaining)
    {
        outHexdump($remaining, "  Unexpected Data");
        error $FH->tell() - $remaining, extraFieldIdentifier($extraID) . ": " . decimalHex0x($remaining) . " unexpected trailing bytes" ;
    }
}

sub decode_Minizip_CD
{
    # 0xcdcd Minizip Central Directory
    # Definition in https://github.com/zlib-ng/minizip-ng/blob/master/doc/mz_extrafield.md#central-directory-0xcdcd

    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    $entry->minizip_secure(1);
    $CentralDirectory->setMiniZipEncrypted();

    my $size = out_Q "  Entries";

 }

sub decode_AES
{
    # ref https://www.winzip.com/en/support/aes-encryption/
    # Document version: 1.04
    # Last modified: January 30, 2009

    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    return if $len == 0 ;

    my $validAES = 1;

    state $lookup = { 1 => "AE-1", 2 => "AE-2" };
    my $vendorVersion = out_v "  Vendor Version", sub {  $lookup->{$_[0]} || "Unknown"  } ;
    if (! $lookup->{$vendorVersion})
    {
        $validAES = 0;
        warning $FH->tell() - 2, extraFieldIdentifier($extraID) . ": Unknown 'Vendor Version' $vendorVersion. Valid values are 1,2"
    }

    my $id ;
    myRead($id, 2);
    my $idValue = out $id, "  Vendor ID", unpackValue_v($id) . " '$id'";

    if ($id ne 'AE')
    {
        $validAES = 0;
        warning $FH->tell() - 2, extraFieldIdentifier($extraID) . ": Unknown 'Vendor ID' '$idValue'. Valid value is 'AE'"
    }

    state $strengths = {1 => "128-bit encryption key",
                        2 => "192-bit encryption key",
                        3 => "256-bit encryption key",
                       };

    my $strength = out_C "  Encryption Strength", sub {$strengths->{$_[0]} || "Unknown" } ;

    if (! $strengths->{$strength})
    {
        $validAES = 0;
        warning $FH->tell() - 1, extraFieldIdentifier($extraID) . ": Unknown 'Encryption Strength' $strength. Valid values are 1,2,3"
    }

    my ($bmethod, $method) = read_v();
    out $bmethod, "  Compression Method", compressionMethod($method) ;
    if (! defined $ZIP_CompressionMethods{$method})
    {
        $validAES = 0;
        warning $FH->tell() - 2, extraFieldIdentifier($extraID) . ": Unknown 'Compression Method' ID " . decimalHex0x($method, 2)
    }

    $entry->aesStrength($strength) ;
    $entry->aesValid($validAES) ;
}

sub decode_Reference
{
    # ref https://www.winzip.com/en/support/compression-methods/

    my $len = shift;
    my $entry = shift;

    out_V "  CRC";
    myRead(my $uuid, 16);
    # UUID is big endian
    out2 $uuid, "UUID",
        unpack('H*', substr($uuid, 0, 4)) . '-' .
        unpack('H*', substr($uuid, 4, 2)) . '-' .
        unpack('H*', substr($uuid, 6, 2)) . '-' .
        unpack('H*', substr($uuid, 8, 2)) . '-' .
        unpack('H*', substr($uuid, 10, 6)) ;
}

sub decode_DUMMY
{
    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    out_V "  Data";
}

sub decode_GrowthHint
{
    # APPNOTE 6.3.10, sec 4.6.10

    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    # caller has checked that 4 bytes are available,
    # so can output values without checking available space
    out_v "  Signature" ;
    out_v "  Initial Value";

    my $padding;
    myRead($padding, $len - 4);

    out2 $padding, "Padding", hexDump16($padding);

    if ($padding !~ /^\x00+$/)
    {
        info $FH->tell(), extraFieldIdentifier($extraID) . ": 'Padding' is not all NULL bytes";
    }
}

sub decode_DataStreamAlignment
{
    # APPNOTE 6.3.10, sec 4.6.11

    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    my $inCentralHdr = $entry->inCentralDir ;

    return if $len == 0 ;

    my ($data, $alignment) = read_v();

    out $data, "  Alignment", Value_v($alignment) ;

    my $recompress_value = $alignment & 0x8000 ? 1 : 0;

    my $recompressing = $recompress_value ? "True" : "False";
    $alignment &= 0x7FFF ;
    my $hexAl =  sprintf("%X", $alignment);

    out1 "  [Bit   15]",  "$recompress_value    'Recompress $recompressing'";
    out1 "  [Bits 0-14]", "$hexAl 'Minimal Alignment $alignment'";

    if (! $inCentralHdr && $len - 2 > 0)
    {
        my $padding;
        myRead($padding, $len - 2);

        out2 $padding, "Padding", hexDump16($padding);
    }
}


sub decode_UX
{
    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    my $inCentralHdr = $entry->inCentralDir ;

    return if $len == 0 ;

    my ($data, $time) = read_V();
    out2 $data, "Access Time", Value_V($time) . " " . getTime($time) ;

    ($data, $time) = read_V();
    out2 $data, "Modification Time", Value_V($time) . " " . getTime($time) ;

    if (! $inCentralHdr ) {
        out_v "  UID" ;
        out_v "  GID";
    }
}

sub decode_Ux
{
    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    return if $len == 0 ;
    out_v "  UID" ;
    out_v "  GID";
}

sub decodeLitteEndian
{
    my $value = shift ;

    if (length $value == 8)
    {
        return unpackValueQ ($value)
    }
    elsif (length $value == 4)
    {
        return unpackValue_V ($value)
    }
    elsif (length $value == 2)
    {
        return unpackValue_v ($value)
    }
    elsif (length $value == 1)
    {
        return unpackValue_C ($value)
    }
    else {
        # TODO - fix this
        internalFatal undef, "unsupported decodeLitteEndian length '" . length ($value) . "'";
    }
}

sub decode_ux
{
    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    # caller has checked that 3 bytes are available

    return if $len == 0 ;

    my $version = out_C "  Version" ;
    info  $FH->tell() - 1, extraFieldIdentifier($extraID) . ": 'Version' should be " . decimalHex0x(1) . ", got " . decimalHex0x($version, 1)
        if $version != 1 ;

    my $available = $len - 1 ;

    my $uidSize = out_C "  UID Size";
    $available -= 1;

    if ($uidSize)
    {
        if ($available < $uidSize)
        {
            outSomeData($available, "  Bad Extra Data");
            error $FH->tell() - $available,
                extraFieldIdentifier($extraID) . ": truncated reading 'UID'",
                expectedMessage($uidSize, $available);
            return;
        }

        myRead(my $data, $uidSize);
        out2 $data, "UID", decodeLitteEndian($data);
        $available -= $uidSize ;
    }

    if ($available < 1)
    {
        error $FH->tell(),
                    extraFieldIdentifier($extraID) . ": truncated reading 'GID Size'",
                    expectedMessage($uidSize, $available);
        return ;
    }

    my $gidSize = out_C "  GID Size";
    $available -= 1 ;
    if ($gidSize)
    {
        if ($available < $gidSize)
        {
            outSomeData($available, "  Bad Extra Data");
            error $FH->tell() - $available,
                        extraFieldIdentifier($extraID) . ": truncated reading 'GID'",
                        expectedMessage($gidSize, $available);
            return;
        }

        myRead(my $data, $gidSize);
        out2 $data, "GID", decodeLitteEndian($data);
        $available -= $gidSize ;
    }

}

sub decode_Java_exe
{
    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

}

sub decode_up
{
    # APPNOTE 6.3.10, sec 4.6.9

    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    out_C "  Version";
    out_V "  NameCRC32";

    if ($len - 5 > 0)
    {
        myRead(my $data, $len - 5);

        outputFilename($data, 1,  "  UnicodeName");
    }
}

sub decode_ASi_Unix
{
    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    # https://stackoverflow.com/questions/76581811/why-does-unzip-ignore-my-zip64-end-of-central-directory-record

    out_V "  CRC";
    my $native_attrib = out_v "  Mode";

    # TODO - move to separate sub & tidy
    if (1) # Unix
    {

        state $mask = {
                0   => '---',
                1   => '--x',
                2   => '-w-',
                3   => '-wx',
                4   => 'r--',
                5   => 'r-x',
                6   => 'rw-',
                7   => 'rwx',
            } ;

        my $rwx = ($native_attrib  &  0777);

        if ($rwx)
        {
            my $output  = '';
            $output .= $mask->{ ($rwx >> 6) & 07 } ;
            $output .= $mask->{ ($rwx >> 3) & 07 } ;
            $output .= $mask->{ ($rwx >> 0) & 07 } ;

            out1 "  [Bits 0-8]",  Value_v($rwx)  . " 'Unix attrib: $output'" ;
            out1 "  [Bit 9]",  "1 'Sticky'"
                if $rwx & 0x200 ;
            out1 "  [Bit 10]",  "1 'Set GID'"
                if $rwx & 0x400 ;
            out1 "  [Bit 11]",  "1 'Set UID'"
                if $rwx & 0x800 ;

            my $not_rwx = (($native_attrib  >> 12) & 0xF);
            if ($not_rwx)
            {
                state $masks = {
                    0x0C =>  'Socket',           # 0x0C  0b1100
                    0x0A =>  'Symbolic Link',    # 0x0A  0b1010
                    0x08 =>  'Regular File',     # 0x08  0b1000
                    0x06 =>  'Block Device',     # 0x06  0b0110
                    0x04 =>  'Directory',        # 0x04  0b0100
                    0x02 =>  'Character Device', # 0x02  0b0010
                    0x01 =>  'FIFO',             # 0x01  0b0001
                };

                my $got = $masks->{$not_rwx} // 'Unknown Unix attrib' ;
                out1 "  [Bits 12-15]",  Value_C($not_rwx) . " '$got'"
            }
        }
    }


    my $s = out_V "  SizDev";
    out_v "  UID";
    out_v "  GID";

}

sub decode_uc
{
    # APPNOTE 6.3.10, sec 4.6.8

    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    out_C "  Version";
    out_V "  ComCRC32";

    if ($len - 5 > 0)
    {
        myRead(my $data, $len - 5);

        outputFilename($data, 1, "  UnicodeCom");
    }
}

sub decode_Xceed_unicode
{
    # 0x554e

    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    my $data ;
    my $remaining = $len;

    # No public definition available, so reverse engineer the content.

    # See https://github.com/pmqs/zipdetails/issues/13 for C# source that populates
    # this field.

    # Fiddler https://www.telerik.com/fiddler) creates this field.

    # Local Header only has UTF16LE filename
    #
    # Field definition
    #    4 bytes Signature                      always XCUN
    #    2 bytes Filename Length (divided by 2)
    #      Filename

    # Central has UTF16LE filename & comment
    #
    # Field definition
    #    4 bytes Signature                      always XCUN
    #    2 bytes Filename Length (divided by 2)
    #    2 bytes Comment Length (divided by 2)
    #      Filename
    #      Comment

    # First 4 bytes appear to be little-endian "XCUN" all the time
    # Just double check
    my ($idb, $id) = read_V();
    $remaining -= 4;

    my $outid = decimalHex0x($id);
    $outid .= " 'XCUN'"
        if $idb eq 'NUCX';

    out $idb, "  ID", $outid;

    # Next 2 bytes contains a count of the filename length divided by 2
    # Dividing by 2 gives the number of UTF-16 characters.
    my $filenameLength = out_v "  Filename Length";
    $filenameLength *= 2; # Double to get number of bytes to read
    $remaining -= 2;

    my $commentLength = 0;

    if ($entry->inCentralDir)
    {
        # Comment length only in Central Directory
        # Again stored divided by 2.
        $commentLength = out_v "  Comment Length";
        $commentLength *= 2; # Double to get number of bytes to read
        $remaining -= 2;
    }

    # next is a UTF16 encoded filename

    if ($filenameLength)
    {
        if ($filenameLength > $remaining )
        {
            myRead($data, $remaining);
            out redactData($data), "  UTF16LE Filename", "'" . redactFilename(decode("UTF16LE", $data)) . "'";

            error $FH->tell() - $remaining,
                extraFieldIdentifier($extraID) .  ": Truncated reading 'UTF16LE Filename'",
                expectedMessage($filenameLength, $remaining);
            return undef;
        }

        myRead($data, $filenameLength);
        out redactData($data), "  UTF16LE Filename", "'" . redactFilename(decode("UTF16LE", $data)) . "'";
        $remaining -= $filenameLength;
    }

    # next is a UTF16 encoded comment

    if ($commentLength)
    {
        if ($commentLength > $remaining )
        {
            myRead($data, $remaining);
            out redactData($data), "  UTF16LE Comment", "'" . redactFilename(decode("UTF16LE", $data)) . "'";

            error $FH->tell() - $remaining,
                extraFieldIdentifier($extraID) .  ": Truncated reading 'UTF16LE Comment'",
                expectedMessage($filenameLength, $remaining);
            return undef;
        }

        myRead($data, $commentLength);
        out redactData($data), "  UTF16LE Comment", "'" . redactFilename(decode("UTF16LE", $data)) . "'";
        $remaining -= $commentLength;
    }

    if ($remaining)
    {
        outHexdump($remaining, "  Unexpected Data");
        error $FH->tell() - $remaining, extraFieldIdentifier($extraID) . ": " . decimalHex0x($remaining) . " unexpected trailing bytes" ;
    }
}

sub decode_Key_Value_Pair
{
    # 0x564B 'KV'
    # https://github.com/sozip/keyvaluepairs-spec/blob/master/zip_keyvalue_extra_field_specification.md

    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    my $remaining = $len;

    myRead(my $signature, 13);
    $remaining -= 13;

    if ($signature ne 'KeyValuePairs')
    {
        error $FH->tell() - 13, extraFieldIdentifier($extraID) . ": 'Signature' field not 'KeyValuePairs'" ;
        myRead(my $payload, $remaining);
        my $data = hexDump16($signature . $payload);

        out2 $signature . $payload, "Extra Payload", $data;

        return ;
    }

    out $signature, '  Signature', "'KeyValuePairs'";
    my $kvPairs = out_C "  KV Count";
    $remaining -= 1;

    for my $index (1 .. $kvPairs)
    {
        my $key;
        my $klen = out_v "  Key size #$index";
        $remaining -= 4;

        myRead($key, $klen);
        outputFilename $key, 1, "  Key #$index";
        $remaining -= $klen;

        my $value;
        my $vlen = out_v "  Value size #$index";
        $remaining -= 4;

        myRead($value, $vlen);
        outputFilename $value, 1, "  Value #$index";
        $remaining -= $vlen;
    }

    # TODO check that
    # * count of kv pairs is accurate
    # * no truncation in middle of kv data
    # * no trailing data
}

sub decode_NT_security
{
    # IZ Appnote
    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    my $inCentralHdr = $entry->inCentralDir ;

    out_V "  Uncompressed Size" ;

    if (! $inCentralHdr) {

        out_C "  Version" ;

        out_v "  CType", sub { "'" . ($ZIP_CompressionMethods{$_[0]} || "Unknown Method") . "'" };

        out_V "  CRC" ;

        my $plen = $len - 4 - 1 - 2 - 4;
        outHexdump $plen, "  Extra Payload";
    }
}

sub decode_MVS
{
    # APPNOTE 6.3.10, Appendix
    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    # data in Big-Endian
    myRead(my $data, $len);
    my $ID = unpack("N", $data);

    if ($ID == 0xE9F3F9F0) # EBCDIC for "Z390"
    {
        my $d = substr($data, 0, 4, '') ;
        out($d, "  ID", "'Z390'");
    }

    out($data, "  Extra Payload", hexDump16($data));
}

sub decode_strong_encryption
{
    # APPNOTE 6.3.10, sec 4.5.12 & 7.4.2

    my $extraID = shift ;
    my $len = shift;
    my $entry = shift;

    # TODO check for overflow is contents > $len
    out_v "  Format";
    out_v "  AlgId", sub { $AlgIdLookup{ $_[0] } // "Unknown algorithm" } ;
    out_v "  BitLen";
    out_v "  Flags", sub { $FlagsLookup{ $_[0] } // "reserved for certificate processing" } ;

    # see APPNOTE 6.3.10, sec 7.4.2 for this part
    my $recipients = out_V "  Recipients";

    my $available = $len - 12;

    if ($recipients)
    {
        if ($available < 2)
        {
            outSomeData($available, "  Badly formed extra data");
            # TODO - need warning
            return;
        }

        out_v "  HashAlg", sub { $HashAlgLookup{ $_[0] } // "Unknown algorithm" } ;
        $available -= 2;

        if ($available < 2)
        {
            outSomeData($available, "  Badly formed extra data");
            # TODO - need warning
            return;
        }

        my $HSize = out_v "  HSize" ;
        $available -= 2;

        # should have $recipients * $HSize bytes available
        if ($recipients * $HSize != $available)
        {
            outSomeData($available, "  Badly formed extra data");
            # TODO - need warning
            return;
        }

        my $ix = 1;
        for (0 .. $recipients-1)
        {
            myRead(my $payload, $HSize);
            my $data = hexDump16($payload);

            out2 $payload, sprintf("Key #%X", $ix), $data;
            ++ $ix;
        }
    }
}


sub printAes
{
    # ref https://www.winzip.com/en/support/aes-encryption/

    my $entry = shift;

    return 0
        if ! $entry->aesValid;

    my %saltSize = (
                        1 => 8,
                        2 => 12,
                        3 => 16,
                    );

    myRead(my $salt, $saltSize{$entry->aesStrength } // 0);
    out $salt, "AES Salt", hexDump16($salt);
    myRead(my $pwv, 2);
    out $pwv, "AES Pwd Ver", hexDump16($pwv);

    return  $saltSize{$entry->aesStrength} + 2 + 10;
}

sub printLzmaProperties
{
    my $len = 0;

    my $b1;
    my $b2;
    my $buffer;

    myRead($b1, 2);
    my ($verHi, $verLow) = unpack ("CC", $b1);

    out $b1, "LZMA Version", sprintf("%02X%02X", $verHi, $verLow) . " '$verHi.$verLow'";
    my $LzmaPropertiesSize = out_v "LZMA Properties Size";
    $len += 4;

    my $LzmaInfo = out_C "LZMA Info",  sub { $_[0] == 93 ? "(Default)" : ""};

    my $PosStateBits = 0;
    my $LiteralPosStateBits = 0;
    my $LiteralContextBits = 0;
    $PosStateBits = int($LzmaInfo / (9 * 5));
	$LzmaInfo -= $PosStateBits * 9 * 5;
	$LiteralPosStateBits = int($LzmaInfo / 9);
	$LiteralContextBits = $LzmaInfo - $LiteralPosStateBits * 9;

    out1 "  PosStateBits",        $PosStateBits;
    out1 "  LiteralPosStateBits", $LiteralPosStateBits;
    out1 "  LiteralContextBits",  $LiteralContextBits;

    out_V "LZMA Dictionary Size";

    # TODO - assumption that this is 5
    $len += $LzmaPropertiesSize;

    skip($FH, $LzmaPropertiesSize - 5)
        if  $LzmaPropertiesSize != 5 ;

    return $len;
}

sub peekAtOffset
{
    # my $fh = shift;
    my $offset = shift;
    my $len = shift;

    my $here = $FH->tell();

    seekTo($offset) ;

    my $buffer;
    myRead($buffer, $len);
    seekTo($here);

    length $buffer == $len
        or return '';

    return $buffer;
}

sub readFromOffset
{
    # my $fh = shift;
    my $offset = shift;
    my $len = shift;

    seekTo($offset) ;

    my $buffer;
    myRead($buffer, $len);

    length $buffer == $len
        or return '';

    return $buffer;
}

sub readSignatureFromOffset
{
    my $offset = shift ;

    # catch use case where attempting to read past EOF
    # sub is expecting to return a 32-bit value so return 54-bit out-of-bound value
    return MAX64
        if $offset + 4 > $FILELEN ;

    my $here = $FH->tell();
    my $buffer = readFromOffset($offset, 4);
    my $gotSig = unpack("V", $buffer) ;
    seekTo($here);

    return $gotSig;
}


sub chckForAPKSigningBlock
{
    my $fh = shift;
    my $cdOffset = shift;
    my $cdSize = shift;

    # APK Signing Block comes directy before the Central directory
    # See https://source.android.com/security/apksigning/v2

    # If offset available is less than 44, it isn't an APK signing block
    #
    #   len1     8
    #   id       4
    #   kv with zero len 8
    #   len1     8
    #   magic   16
    #   ----------
    #           44

    return (0, 0, '')
        if $cdOffset < 44 || $FILELEN - $cdSize < 44 ;

    # Step 1 - 16 bytes before CD is literal string "APK Sig Block 42"
    my $magicOffset = $cdOffset - 16;
    my $buffer = readFromOffset($magicOffset, 16);

    return (0, 0, '')
        if $buffer ne "APK Sig Block 42" ;

    # Step 2 - read the second length field
    #          and check that it looks ok
    $buffer = readFromOffset($cdOffset - 16 - 8, 8);
    my $len2 = unpack("Q<", $buffer);

    return (0, 0, '')
        if $len2 == 0 || $len2 > $FILELEN;

    # Step 3 - read the first length field.
    #          It should be identical to the second one.

    my $startApkOffset = $cdOffset -  8 - $len2 ;

    $buffer = readFromOffset($startApkOffset, 8);
    my $len1 = unpack("Q<", $buffer);

    return (0, 0, '')
        if $len1 != $len2;

    return ($startApkOffset, $cdOffset - 16 - 8, $buffer);
}

sub scanApkBlock
{
    state $IDs = {
            0x7109871a  => "APK Signature v2",
            0xf05368c0  => "APK Signature v3",
            0x42726577  => "Verity Padding Block", # from https://android.googlesource.com/platform/tools/apksig/+/master/src/main/java/com/android/apksig/internal/apk/ApkSigningBlockUtils.java
            0x6dff800d  => "Source Stamp",
            0x504b4453  => "Dependency Info",
            0x71777777  => "APK Channel Block",
            0xff3b5998  => "Zero Block",
            0x2146444e  => "Play Metadata",
    } ;


    seekTo($FH->tell() - 4) ;
    print "\n";
    out "", "APK SIGNING BLOCK";

    scanApkPadding();
    out_Q "Block Length Copy #1";
    my $ix = 1;

    while ($FH->tell() < $APK - 8)
    {
         my ($bytes, $id, $len);
        ($bytes, $len) = read_Q ;
        out $bytes, "ID/Value Length #" . sprintf("%X", $ix), Value_Q($len);

        ($bytes, $id) = read_V;

        out $bytes, "  ID", Value_V($id) . " '" . ($IDs->{$id} // 'Unknown ID') . "'";

        outSomeData($len-4, "  Value");
        ++ $ix;
    }

    out_Q "Block Length Copy #2";

    my $magic ;
    myRead($magic, 16);

    out $magic, "Magic", qq['$magic'];
}

sub scanApkPadding
{
    my $here = $FH->tell();

    return
        if $here == $START_APK;

    # found some padding

    my $delta = $START_APK - $here;
    my $padding = peekAtOffset($here, $delta);

    if ($padding =~ /^\x00+$/)
    {
        outSomeData($delta, "Null Padding");
    }
    else
    {
        outHexdump($delta, "Unexpected Padding");
    }
}

sub scanCentralDirectory
{
    my $fh = shift;

    my $here = $fh->tell();

    # Use cases
    # 1 32-bit CD
    # 2 64-bit CD

    my ($offset, $size) = findCentralDirectoryOffset($fh);
    $CentralDirectory->{CentralDirectoryOffset} = $offset;
    $CentralDirectory->{CentralDirectorySize} = $size;

    return ()
        if ! defined $offset;

    $fh->seek($offset, SEEK_SET) ;

    # Now walk the Central Directory Records
    my $buffer ;
    my $cdIndex = 0;
    my $cdEntryOffset = 0;

    while ($fh->read($buffer, ZIP_CD_FILENAME_OFFSET) == ZIP_CD_FILENAME_OFFSET  &&
           unpack("V", $buffer) == ZIP_CENTRAL_HDR_SIG) {

        my $startHeader = $fh->tell() - ZIP_CD_FILENAME_OFFSET;

        my $cdEntryOffset = $fh->tell() - ZIP_CD_FILENAME_OFFSET;
        $HeaderOffsetIndex->addOffsetNoPrefix($cdEntryOffset, ZIP_CENTRAL_HDR_SIG) ;

        ++ $cdIndex ;

        my $extractVer         = unpack("v", substr($buffer,  6, 1));
        my $gpFlag             = unpack("v", substr($buffer,  8, 2));
        my $lastMod            = unpack("V", substr($buffer, 10, 4));
        my $crc                = unpack("V", substr($buffer, 16, 4));
        my $compressedSize   = unpack("V", substr($buffer, 20, 4));
        my $uncompressedSize = unpack("V", substr($buffer, 24, 4));
        my $filename_length    = unpack("v", substr($buffer, 28, 2));
        my $extra_length       = unpack("v", substr($buffer, 30, 2));
        my $comment_length     = unpack("v", substr($buffer, 32, 2));
        my $diskNumber         = unpack("v", substr($buffer, 34, 2));
        my $locHeaderOffset    = unpack("V", substr($buffer, 42, 4));

        my $cdZip64 = 0;
        my $zip64Sizes = 0;

        if (! full32 $locHeaderOffset)
        {
            # Check for corrupt offset
            # 1. ponting paset EOF
            # 2. offset points forward in the file
            # 3. value at offset is not a CD record signature

            my $commonMessage = "'Local Header Offset' field in '" . Signatures::name(ZIP_CENTRAL_HDR_SIG) . "' is invalid";
            checkOffsetValue($locHeaderOffset, $startHeader, 0, $commonMessage,
                $startHeader + CentralDirectoryEntry::Offset_RelativeOffsetToLocal(),
                ZIP_LOCAL_HDR_SIG, 1) ;
        }

        $fh->read(my $filename, $filename_length) ;

        my $cdEntry = CentralDirectoryEntry->new();

        $cdEntry->centralHeaderOffset($startHeader) ;
        $cdEntry->localHeaderOffset($locHeaderOffset) ;
        $cdEntry->compressedSize($compressedSize) ;
        $cdEntry->uncompressedSize($uncompressedSize) ;
        $cdEntry->extractVersion($extractVer);
        $cdEntry->generalPurposeFlags($gpFlag);
        $cdEntry->filename($filename) ;
        $cdEntry->lastModDateTime($lastMod);
        $cdEntry->languageEncodingFlag($gpFlag & ZIP_GP_FLAG_LANGUAGE_ENCODING) ;
        $cdEntry->diskNumber($diskNumber) ;
        $cdEntry->crc32($crc) ;
        $cdEntry->zip64ExtraPresent($cdZip64) ;

        $cdEntry->std_localHeaderOffset($locHeaderOffset) ;
        $cdEntry->std_compressedSize($compressedSize) ;
        $cdEntry->std_uncompressedSize($uncompressedSize) ;
        $cdEntry->std_diskNumber($diskNumber) ;


        if ($extra_length)
        {
            $fh->read(my $extraField, $extra_length) ;

            # Check for Zip64
            my $zip64Extended = findID(0x0001, $extraField);

            if ($zip64Extended)
            {
                $cdZip64 = 1;
                walk_Zip64_in_CD(1, $zip64Extended, $cdEntry, 0);
            }
        }

        $cdEntry->offsetStart($startHeader) ;
        $cdEntry->offsetEnd($FH->tell() - 1);

        # don't call addEntry until after the extra fields have been scanned
        # the localheader offset value may be updated in th ezip64 extra field.
        $CentralDirectory->addEntry($cdEntry);
        $HeaderOffsetIndex->addOffset($cdEntry->localHeaderOffset, ZIP_LOCAL_HDR_SIG) ;

        skip($fh, $comment_length ) ;
    }

    $FH->seek($fh->tell() - ZIP_CD_FILENAME_OFFSET, SEEK_SET);

    # Check for Digital Signature
    $HeaderOffsetIndex->addOffset($fh->tell() - 4, ZIP_DIGITAL_SIGNATURE_SIG)
        if $fh->read($buffer, 4) == 4  &&
            unpack("V", $buffer) == ZIP_DIGITAL_SIGNATURE_SIG ;

    $CentralDirectory->sortByLocalOffset();
    $HeaderOffsetIndex->sortOffsets();

    $fh->seek($here, SEEK_SET) ;

}

use constant ZIP64_END_CENTRAL_LOC_HDR_SIZE     => 20;
use constant ZIP64_END_CENTRAL_REC_HDR_MIN_SIZE => 56;

sub offsetFromZip64
{
    my $fh = shift ;
    my $here = shift;
    my $eocdSize = shift;

    #### Zip64 end of central directory locator

    # check enough bytes available for zip64 locator record
    fatal_tryWalk undef, "Cannot find signature for " .  Signatures::nameAndHex(ZIP64_END_CENTRAL_LOC_HDR_SIG), # 'Zip64 end of central directory locator': 0x07064b50"
                         "Possible truncated or corrupt zip file"
        if $here < ZIP64_END_CENTRAL_LOC_HDR_SIZE ;

    $fh->seek($here - ZIP64_END_CENTRAL_LOC_HDR_SIZE, SEEK_SET) ;
    $here = $FH->tell();

    my $buffer;
    my $got = 0;
    $fh->read($buffer, ZIP64_END_CENTRAL_LOC_HDR_SIZE);

    my $gotSig = unpack("V", $buffer);
    fatal_tryWalk $here - 4, sprintf("Expected signature for " . Signatures::nameAndHex(ZIP64_END_CENTRAL_LOC_HDR_SIG) . " not found, got 0x%X", $gotSig)
        if $gotSig != ZIP64_END_CENTRAL_LOC_HDR_SIG ;

    $HeaderOffsetIndex->addOffset($fh->tell() - ZIP64_END_CENTRAL_LOC_HDR_SIZE, ZIP64_END_CENTRAL_LOC_HDR_SIG) ;


    my $cd64 = unpack "Q<", substr($buffer,  8, 8);
    my $totalDisks = unpack "V", substr($buffer,  16, 4);

    testPossiblePrefix($cd64, ZIP64_END_CENTRAL_REC_HDR_SIG);

    if ($totalDisks > 0)
    {
        my $commonMessage = "'Offset to Zip64 End of Central Directory Record' field in '" . Signatures::name(ZIP64_END_CENTRAL_LOC_HDR_SIG) . "' is invalid";
        $cd64 = checkOffsetValue($cd64, $here, 0, $commonMessage, $here + 8, ZIP64_END_CENTRAL_REC_HDR_SIG, 1) ;
    }

    my $delta = $here - $cd64;

    #### Zip64 end of central directory record

    my $zip64eocd_name = "'" . Signatures::name(ZIP64_END_CENTRAL_REC_HDR_SIG) . "'";
    my $zip64eocd_name_value = Signatures::nameAndHex(ZIP64_END_CENTRAL_REC_HDR_SIG);
    my $zip64eocd_value = Signatures::hexValue(ZIP64_END_CENTRAL_REC_HDR_SIG);

    # check enough bytes available
    # fatal_tryWalk sprintf "Size of 'Zip64 End of Central Directory Record' 0x%X too small", $cd64
    fatal_tryWalk undef, sprintf "Size of $zip64eocd_name 0x%X too small", $cd64
        if $delta < ZIP64_END_CENTRAL_REC_HDR_MIN_SIZE;

    # Seek to Zip64 End of Central Directory Record
    $fh->seek($cd64, SEEK_SET) ;
    $HeaderOffsetIndex->addOffsetNoPrefix($fh->tell(), ZIP64_END_CENTRAL_REC_HDR_SIG) ;

    $fh->read($buffer, ZIP64_END_CENTRAL_REC_HDR_MIN_SIZE) ;

    my $sig = unpack("V", substr($buffer, 0, 4)) ;
    fatal_tryWalk undef, sprintf "Cannot find $zip64eocd_name: expected $zip64eocd_value but got 0x%X", $sig
        if $sig != ZIP64_END_CENTRAL_REC_HDR_SIG ;

    # pkzip sets the extract zip spec to 6.2 (0x3E) to signal a v2 record
    # See APPNOTE 6.3.10, section, 7.3.3

    # Version 1 header is 44 bytes (assuming no extensible data sector)
    # Version 2 header (see APPNOTE 6.3.7, section) is > 44 bytes

    my $extractSpec         = unpack "C",  substr($buffer, 14, 1);
    my $diskNumber          = unpack "V",  substr($buffer, 16, 4);
    my $cdDiskNumber        = unpack "V",  substr($buffer, 20, 4);
    my $entriesOnThisDisk   = unpack "Q<", substr($buffer, 24, 8);
    my $totalEntries        = unpack "Q<", substr($buffer, 32, 8);
    my $centralDirSize      = unpack "Q<", substr($buffer, 40, 8);
    my $centralDirOffset    = unpack "Q<", substr($buffer, 48, 8);

    if ($extractSpec >= 0x3E)
    {
        $opt_walk = 1;
        $CentralDirectory->setPkEncryptedCD();
    }

    if (! emptyArchive($here, $diskNumber, $cdDiskNumber, $entriesOnThisDisk, $totalEntries,  $centralDirSize, $centralDirOffset))
    {
        my $commonMessage = "'Offset to Central Directory' field in $zip64eocd_name is invalid";
        $centralDirOffset = checkOffsetValue($centralDirOffset, $here, 0, $commonMessage, $here + 48, ZIP_CENTRAL_HDR_SIG, 1, $extractSpec < 0x3E) ;
    }

    # TODO - APPNOTE allows an extensible data sector here (see APPNOTE 6.3.10, section 4.3.14.2) -- need to take this into account

    return ($centralDirOffset, $centralDirSize) ;
}

use constant Pack_ZIP_END_CENTRAL_HDR_SIG => pack("V", ZIP_END_CENTRAL_HDR_SIG);

sub findCentralDirectoryOffset
{
    my $fh = shift ;

    # Most common use-case is where there is no comment, so
    # know exactly where the end of central directory record
    # should be.

    need ZIP_EOCD_MIN_SIZE, Signatures::name(ZIP_END_CENTRAL_HDR_SIG);

    $fh->seek(-ZIP_EOCD_MIN_SIZE(), SEEK_END) ;
    my $here = $fh->tell();

    my $is64bit = $here > MAX32;
    my $over64bit = $here  & (~ MAX32);

    my $buffer;
    $fh->read($buffer, ZIP_EOCD_MIN_SIZE);

    my $zip64 = 0;
    my $diskNumber ;
    my $cdDiskNumber ;
    my $entriesOnThisDisk ;
    my $totalEntries ;
    my $centralDirSize ;
    my $centralDirOffset ;
    my $commentLength = 0;
    my $trailingBytes = 0;

    if ( unpack("V", $buffer) == ZIP_END_CENTRAL_HDR_SIG ) {

        $HeaderOffsetIndex->addOffset($here + $PREFIX_DELTA, ZIP_END_CENTRAL_HDR_SIG) ;

        $diskNumber       = unpack("v", substr($buffer, 4,   2));
        $cdDiskNumber     = unpack("v", substr($buffer, 6,   2));
        $entriesOnThisDisk= unpack("v", substr($buffer, 8,   2));
        $totalEntries     = unpack("v", substr($buffer, 10,  2));
        $centralDirSize   = unpack("V", substr($buffer, 12,  4));
        $centralDirOffset = unpack("V", substr($buffer, 16,  4));
        $commentLength    = unpack("v", substr($buffer, 20,  2));
    }
    else {
        $fh->seek(0, SEEK_END) ;

        my $fileLen = $fh->tell();
        my $want = 0 ;

        while(1) {
            $want += 1024 * 32;
            my $seekTo = $fileLen - $want;
            if ($seekTo < 0 ) {
                $seekTo = 0;
                $want = $fileLen ;
            }
            $fh->seek( $seekTo, SEEK_SET);
            $fh->read($buffer, $want) ;
            my $pos = rindex( $buffer, Pack_ZIP_END_CENTRAL_HDR_SIG);

            if ($pos >= 0 && $want - $pos > ZIP_EOCD_MIN_SIZE) {
                $here = $seekTo + $pos ;
                $HeaderOffsetIndex->addOffset($here + $PREFIX_DELTA, ZIP_END_CENTRAL_HDR_SIG) ;

                $diskNumber       = unpack("v", substr($buffer, $pos + 4,   2));
                $cdDiskNumber     = unpack("v", substr($buffer, $pos + 6,   2));
                $entriesOnThisDisk= unpack("v", substr($buffer, $pos + 8,   2));
                $totalEntries     = unpack("v", substr($buffer, $pos + 10,  2));
                $centralDirSize   = unpack("V", substr($buffer, $pos + 12,  4));
                $centralDirOffset = unpack("V", substr($buffer, $pos + 16,  4));
                $commentLength    = unpack("v", substr($buffer, $pos + 20,  2)) // 0;

                my $expectedEof = $fileLen - $want + $pos + ZIP_EOCD_MIN_SIZE + $commentLength  ;
                # check for trailing data after end of zip
                if ($expectedEof < $fileLen ) {
                    $TRAILING = $expectedEof ;
                    $trailingBytes = $FILELEN - $expectedEof ;
                }
                last ;
            }

            return undef
                if $want == $fileLen;

        }
    }

    $EOCD_Present = 1;

    # Empty zip file can just contain an EOCD record
    return (0, 0)
        if ZIP_EOCD_MIN_SIZE + $commentLength + $trailingBytes  == $FILELEN ;

    if (needZip64EOCDLocator($diskNumber, $cdDiskNumber, $entriesOnThisDisk, $totalEntries, $centralDirOffset, $centralDirSize) &&
        ! emptyArchive($here, $diskNumber, $cdDiskNumber, $entriesOnThisDisk, $totalEntries, $centralDirOffset, $centralDirSize))
    {
        ($centralDirOffset, $centralDirSize) = offsetFromZip64($fh, $here, ZIP_EOCD_MIN_SIZE + $commentLength + $trailingBytes)
    }
    elsif ($is64bit)
    {
        # use-case is where a 64-bit zip file doesn't use the 64-bit
        # extensions.
        # print "EOCD not 64-bit $centralDirOffset ($here)\n" ;

        fatal_tryWalk $here, "Zip file > 4Gig. Expected 'Offset to Central Dir' to be 0xFFFFFFFF, got " . hexValue($centralDirOffset);

        $centralDirOffset += $over64bit;
        $is64In32 = 1;
    }
    else
    {
        if ($centralDirSize)
        {
            my $commonMessage = "'Offset to Central Directory' field in '" . Signatures::name(ZIP_END_CENTRAL_HDR_SIG) . "' is invalid";
            $centralDirOffset = checkOffsetValue($centralDirOffset, $here, $centralDirSize, $commonMessage, $here + 16, ZIP_CENTRAL_HDR_SIG, 1) ;
        }
    }

    return (0, 0)
        if  $totalEntries == 0 && $entriesOnThisDisk == 0;

    # APK Signing Block is directly before the first CD entry
    # Check if it is present
    ($START_APK, $APK, $APK_LEN) = chckForAPKSigningBlock($fh, $centralDirOffset, ZIP_EOCD_MIN_SIZE + $commentLength);

    return ($centralDirOffset, $centralDirSize) ;
}

sub findID
{
    my $id_want = shift ;
    my $data    = shift;

    my $XLEN = length $data ;

    my $offset = 0 ;
    while ($offset < $XLEN) {

        return undef
            if $offset + ZIP_EXTRA_SUBFIELD_HEADER_SIZE  > $XLEN ;

        my $id = substr($data, $offset, ZIP_EXTRA_SUBFIELD_ID_SIZE);
        $id = unpack("v", $id);
        $offset += ZIP_EXTRA_SUBFIELD_ID_SIZE;

        my $subLen =  unpack("v", substr($data, $offset,
                                            ZIP_EXTRA_SUBFIELD_LEN_SIZE));
        $offset += ZIP_EXTRA_SUBFIELD_LEN_SIZE ;

        return undef
            if $offset + $subLen > $XLEN ;

        return substr($data, $offset, $subLen)
            if $id eq $id_want ;

        $offset += $subLen ;
    }

    return undef ;
}


sub nibbles
{
    my @nibbles = (
        [ 16 => 0x1000000000000000 ],
        [ 15 => 0x100000000000000 ],
        [ 14 => 0x10000000000000 ],
        [ 13 => 0x1000000000000 ],
        [ 12 => 0x100000000000 ],
        [ 11 => 0x10000000000 ],
        [ 10 => 0x1000000000 ],
        [  9 => 0x100000000 ],
        [  8 => 0x10000000 ],
        [  7 => 0x1000000 ],
        [  6 => 0x100000 ],
        [  5 => 0x10000 ],
        [  4 => 0x1000 ],
        [  4 => 0x100 ],
        [  4 => 0x10 ],
        [  4 => 0x1 ],
    );
    my $value = shift ;

    for my $pair (@nibbles)
    {
        my ($count, $limit) = @{ $pair };

        return $count
            if $value >= $limit ;
    }
}

{
    package HeaderOffsetEntry;

    sub new
    {
        my $class = shift ;
        my $offset = shift ;
        my $signature = shift;

        bless [ $offset, $signature, Signatures::name($signature)] , $class;

    }

    sub offset
    {
        my $self = shift;
        return $self->[0];
    }

    sub signature
    {
        my $self = shift;
        return $self->[1];
    }

    sub name
    {
        my $self = shift;
        return $self->[2];
    }

}

{
    package HeaderOffsetIndex;

    # Store a list of header offsets recorded when scannning the central directory

    sub new
    {
        my $class = shift ;

        my %object = (
                        'offsetIndex'       => [],
                        'offset2Index'      => {},
                        'offset2Signature'  => {},
                        'currentIndex'      => -1,
                        'currentSignature'  => 0,
                        # 'sigNames'          => $sigNames,
                     ) ;

        bless \%object, $class;
    }

    sub sortOffsets
    {
        my $self = shift ;

        @{ $self->{offsetIndex} } = sort { $a->[0] <=> $b->[0] }
                                    @{ $self->{offsetIndex} };
        my $ix = 0;
        $self->{offset2Index}{$_} = $ix++
            for @{ $self->{offsetIndex} } ;
    }

    sub addOffset
    {
        my $self = shift ;
        my $offset = shift ;
        my $signature = shift ;

        $offset += $PREFIX_DELTA ;
        $self->addOffsetNoPrefix($offset, $signature);
    }

    sub addOffsetNoPrefix
    {
        my $self = shift ;
        my $offset = shift ;
        my $signature = shift ;

        my $name = Signatures::name($signature);

        if (! defined $self->{offset2Signature}{$offset})
        {
            push @{ $self->{offsetIndex} }, HeaderOffsetEntry->new($offset, $signature) ;
            $self->{offset2Signature}{$offset} = $signature;
        }
    }

    sub getNextIndex
    {
        my $self = shift ;
        my $offset = shift ;

        $self->{currentIndex} ++;

        return ${ $self->{offsetIndex} }[$self->{currentIndex}] // undef
    }

    sub rewindIndex
    {
        my $self = shift ;
        my $offset = shift ;

        $self->{currentIndex} --;
    }

    sub dump
    {
        my $self = shift;

        say "### HeaderOffsetIndex";
        say "###   Offset\tSignature";
        for my $x ( @{ $self->{offsetIndex} } )
        {
            my ($offset, $sig) = @$x;
            printf "###   %X %d\t\t" . $x->name() . "\n", $x->offset(), $x->offset();
        }
    }

    sub checkForOverlap
    {
        my $self = shift ;
        my $need = shift;

        my $needOffset = $FH->tell() + $need;

        for my $hdrOffset (@{ $self->{offsetIndex} })
        {
            my $delta = $hdrOffset - $needOffset;
            return [$self->{offsetIndex}{$hdrOffset}, $needOffset - $hdrOffset]
                if $delta <= 0 ;
        }

        return [undef, undef];
    }

}

{
    package FieldsAndAccessors;

    sub Add
    {
        use Data::Dumper ;

        my $classname = shift;
        my $object = shift;
        my $fields = shift ;
        my $no_handler = shift // {};

        state $done = {};


        while (my ($name, $value) =  each %$fields)
        {
            my $method = "${classname}::$name";

            $object->{$name} = $value;

            # don't auto-create a handler
            next
                if $no_handler->{$name};

            no strict 'refs';

            # Don't use lvalue sub for now - vscode debugger breaks with it enabled.
            # https://github.com/richterger/Perl-LanguageServer/issues/194
            # *$method = sub : lvalue {
            #     $_[0]->{$name} ;
            # }
            # unless defined $done->{$method};

            # Auto-generate getter/setter
            *$method = sub  {
                $_[0]->{$name} = $_[1]
                    if @_ == 2;
                return $_[0]->{$name} ;
            }
            unless defined $done->{$method};

            ++ $done->{$method};


        }
    }
}

{
    package BaseEntry ;

    sub new
    {
        my $class = shift ;

        state $index = 0;

        my %fields = (
                        'index'                 => $index ++,
                        'zip64'                 => 0,
                        'offsetStart'           => 0,
                        'offsetEnd'             => 0,
                        'inCentralDir'          => 0,
                        'encapsulated'          => 0, # enclosed in outer zip
                        'childrenCount'         => 0, # this entry is a zip with enclosed children
                        'streamed'              => 0,
                        'languageEncodingFlag'  => 0,
                        'entryType'             => 0,
                     ) ;

        my $self = bless {}, $class;

        FieldsAndAccessors::Add($class, $self, \%fields) ;

        return $self;
    }

    sub increment_childrenCount
    {
        my $self = shift;
        $self->{childrenCount} ++;
    }
}

{
    package LocalCentralEntryBase ;

    use parent -norequire , 'BaseEntry' ;

    sub new
    {
        my $class = shift ;

        my $self = $class->SUPER::new();


        my %fields = (
                        # fields from the header
                        'centralHeaderOffset'   => 0,
                        'localHeaderOffset'     => 0,

                        'extractVersion'        => 0,
                        'generalPurposeFlags'   => 0,
                        'compressedMethod'      => 0,
                        'lastModDateTime'       => 0,
                        'crc32'                 => 0,
                        'compressedSize'        => 0,
                        'uncompressedSize'      => 0,
                        'filename'              => '',
                        'outputFilename'        => '',
                        # inferred data
                        # 'InCentralDir'          => 0,
                        # 'zip64'                 => 0,

                        'zip64ExtraPresent'     => 0,
                        'zip64SizesPresent'     => 0,
                        'payloadOffset'         => 0,

                        # zip64 extra
                        'zip64_compressedSize'    => undef,
                        'zip64_uncompressedSize'  => undef,
                        'zip64_localHeaderOffset' => undef,
                        'zip64_diskNumber'        => undef,
                        'zip64_diskNumberPresent' => 0,

                        # Values direct from the header before merging any Zip64 values
                        'std_compressedSize'    => undef,
                        'std_uncompressedSize'  => undef,
                        'std_localHeaderOffset' => undef,
                        'std_diskNumber'        => undef,

                        # AES
                        'aesStrength'             => 0,
                        'aesValid'                => 0,

                        # Minizip CD encryption
                        'minizip_secure'          => 0,

                     ) ;

        FieldsAndAccessors::Add($class, $self, \%fields) ;

        return $self;
    }
}

{
    package Zip64EndCentralHeaderEntry ;

    use parent -norequire , 'LocalCentralEntryBase' ;

    sub new
    {
        my $class = shift ;

        my $self = $class->SUPER::new();


        my %fields = (
                        'inCentralDir'          => 1,
                     ) ;

        FieldsAndAccessors::Add($class, $self, \%fields) ;

        return $self;
    }

}

{
    package CentralDirectoryEntry;

    use parent -norequire , 'LocalCentralEntryBase' ;

    use constant Offset_VersionMadeBy           => 4;
    use constant Offset_VersionNeededToExtract  => 6;
    use constant Offset_GeneralPurposeFlags     => 8;
    use constant Offset_CompressionMethod       => 10;
    use constant Offset_ModificationTime        => 12;
    use constant Offset_ModificationDate        => 14;
    use constant Offset_CRC32                   => 16;
    use constant Offset_CompressedSize          => 20;
    use constant Offset_UncompressedSize        => 24;
    use constant Offset_FilenameLength          => 28;
    use constant Offset_ExtraFieldLength        => 30;
    use constant Offset_FileCommentLength       => 32;
    use constant Offset_DiskNumber              => 34;
    use constant Offset_InternalAttributes      => 36;
    use constant Offset_ExternalAttributes      => 38;
    use constant Offset_RelativeOffsetToLocal   => 42;
    use constant Offset_Filename                => 46;

    sub new
    {
        my $class = shift ;
        my $offset = shift;

        # check for existing entry
        return $CentralDirectory->{byCentralOffset}{$offset}
            if defined $offset && defined $CentralDirectory->{byCentralOffset}{$offset} ;

        my $self = $class->SUPER::new();

        my %fields = (
                        'diskNumber'                => 0,
                        'comment'                   => "",
                        'ldEntry'                   => undef,
                     ) ;

        FieldsAndAccessors::Add($class, $self, \%fields) ;

        $self->inCentralDir(1) ;
        $self->entryType(::ZIP_CENTRAL_HDR_SIG) ;

        return $self;
    }
}

{
    package CentralDirectory;

    sub new
    {
        my $class = shift ;

        my %object = (
                        'entries'       => [],
                        'count'         => 0,
                        'byLocalOffset' => {},
                        'byCentralOffset' => {},
                        'byName'        => {},
                        'offset2Index' => {},
                        'normalized_filenames' => {},
                        'CentralDirectoryOffset'      => 0,
                        'CentralDirectorySize'      => 0,
                        'zip64'         => 0,
                        'encryptedCD'   => 0,
                        'minizip_secure' => 0,
                        'alreadyScanned' => 0,
                     ) ;

        bless \%object, $class;
    }

    sub addEntry
    {
        my $self = shift ;
        my $entry = shift ;

        my $localHeaderOffset = $entry->localHeaderOffset  ;
        my $CentralDirectoryOffset = $entry->centralHeaderOffset ;
        my $filename = $entry->filename ;

        Nesting::add($entry);

        # Create a reference from Central to Local header entries
        my $ldEntry = Nesting::getLdEntryByOffset($localHeaderOffset);
        if ($ldEntry)
        {
            $entry->ldEntry($ldEntry) ;

            # LD -> CD
            # can have multiple LD entries point to same CD
            # so need to keep a list
            $ldEntry->addCdEntry($entry);
        }

        # only check for duplicate in real CD scan
        if ($self->{alreadyScanned} && ! $entry->encapsulated )
        {
            my $existing = $self->{byName}{$filename} ;
            if ($existing && $existing->centralHeaderOffset != $entry->centralHeaderOffset)
            {
                ::error $CentralDirectoryOffset,
                        "Duplicate Central Directory entries for filename '$filename'",
                        "Current Central Directory entry at offset " . ::decimalHex0x($CentralDirectoryOffset),
                        "Duplicate Central Directory entry at offset " . ::decimalHex0x($self->{byName}{$filename}{centralHeaderOffset});

                # not strictly illegal to have duplicate filename, so save this one
            }
            else
            {
                my $existingNormalizedEntry = $self->normalize_filename($entry, $filename);
                if ($existingNormalizedEntry)
                {
                    ::warning $CentralDirectoryOffset,
                            "Portability Issue: Found case-insensitive duplicate for filename '$filename'",
                            "Current Central Directory entry at offset " . ::decimalHex0x($CentralDirectoryOffset),
                            "Duplicate Central Directory entry for filename '" . $existingNormalizedEntry->outputFilename . "' at offset " . ::decimalHex0x($existingNormalizedEntry->centralHeaderOffset);
                }
            }
        }

        # CD can get processed twice, so return if already processed
        return
            if $self->{byCentralOffset}{$CentralDirectoryOffset} ;

        if (! $entry->encapsulated )
        {
            push @{ $self->{entries} }, $entry;

            $self->{byLocalOffset}{$localHeaderOffset} = $entry;
            $self->{byCentralOffset}{$CentralDirectoryOffset} = $entry;
            $self->{byName}{ $filename } = $entry;
            $self->{offset2Index} = $self->{count} ++;
        }

    }

    sub exists
    {
        my $self = shift ;

        return scalar @{ $self->{entries} };
    }

    sub sortByLocalOffset
    {
        my $self = shift ;

        @{ $self->{entries} } = sort { $a->localHeaderOffset() <=> $b->localHeaderOffset() }
                                @{ $self->{entries} };
    }

    sub getByLocalOffset
    {
        my $self = shift ;
        my $offset = shift ;

        # TODO - what happens if none exists?
        my $entry = $self->{byLocalOffset}{$offset - $PREFIX_DELTA} ;
        return $entry ;
    }

    sub localOffset
    {
        my $self = shift ;
        my $offset = shift ;

        # TODO - what happens if none exists?
        return $self->{byLocalOffset}{$offset - $PREFIX_DELTA} ;
    }

    sub getNextLocalOffset
    {
        my $self = shift ;
        my $offset = shift ;

        my $index = $self->{offset2Index} ;

        if ($index + 1 >= $self->{count})
        {
            return 0;
        }

        return ${ $self->{entries} }[$index+1]->localHeaderOffset() ;
    }

    sub inCD
    {
        my $self = shift ;
        $FH->tell() >= $self->{CentralDirectoryOffset};
    }

    sub setPkEncryptedCD
    {
        my $self = shift ;

        $self->{encryptedCD} = 1 ;

    }

    sub setMiniZipEncrypted
    {
        my $self = shift ;

        $self->{minizip_secure} = 1 ;
    }

    sub isMiniZipEncrypted
    {
        my $self = shift ;
        return $self->{minizip_secure};
    }

    sub isEncryptedCD
    {
        my $self = shift ;
        return $self->{encryptedCD} && ! $self->{minizip_secure};
    }

    sub normalize_filename
    {
        # check if there is a filename that already exists
        # with the same name when normalized to lower case

        my $self = shift ;
        my $entry = shift;
        my $filename = shift;

        my $nFilename = lc $filename;

        my $lookup = $self->{normalized_filenames}{$nFilename};
        # if ($lookup && $lookup ne $filename)
        if ($lookup)
        {
            return $lookup,
        }

        $self->{normalized_filenames}{$nFilename} = $entry;

        return undef;
    }
}

{
    package LocalDirectoryEntry;

    use parent -norequire , 'LocalCentralEntryBase' ;

    use constant Offset_VersionNeededToExtract  => 4;
    use constant Offset_GeneralPurposeFlags     => 6;
    use constant Offset_CompressionMethod       => 8;
    use constant Offset_ModificationTime        => 10;
    use constant Offset_ModificationDate        => 12;
    use constant Offset_CRC32                   => 14;
    use constant Offset_CompressedSize          => 18;
    use constant Offset_UncompressedSize        => 22;
    use constant Offset_FilenameLength          => 26;
    use constant Offset_ExtraFieldLength        => 27;
    use constant Offset_Filename                => 30;

    sub new
    {
        my $class = shift ;

        my $self = $class->SUPER::new();

        my %fields = (
                        'streamedMatch'         => 0,
                        'readDataDescriptor'    => 0,
                        'cdEntryIndex'          => {},
                        'cdEntryList'           => [],
                     ) ;

        FieldsAndAccessors::Add($class, $self, \%fields) ;

        $self->inCentralDir(0) ;
        $self->entryType(::ZIP_LOCAL_HDR_SIG) ;

        return $self;
    }

    sub addCdEntry
    {
        my $self = shift ;
        my $entry = shift;

        # don't want encapsulated entries
        # and protect against duplicates
        return
            if $entry->encapsulated ||
               $self->{cdEntryIndex}{$entry->index} ++ >= 1;

        push @{ $self->{cdEntryList} }, $entry ;
    }

    sub getCdEntry
    {
        my $self = shift ;

        return []
            if ! $self->{cdEntryList} ;

        return $self->{cdEntryList}[0] ;
    }

    sub getCdEntries
    {
        my $self = shift ;
        return $self->{cdEntryList} ;
    }
}

{
    package LocalDirectory;

    sub new
    {
        my $class = shift ;

        my %object = (
                        'entries'       => [],
                        'count'         => 0,
                        'byLocalOffset' => {},
                        'byName'        => {},
                        'offset2Index' => {},
                        'normalized_filenames' => {},
                        'CentralDirectoryOffset'      => 0,
                        'CentralDirectorySize'      => 0,
                        'zip64'         => 0,
                        'encryptedCD'   => 0,
                        'streamedPresent' => 0,
                     ) ;

        bless \%object, $class;
    }

    sub isLocalEntryNested
    {
        my $self = shift ;
        my $localEntry = shift;

        return Nesting::getFirstEncapsulation($localEntry);

    }

    sub addEntry
    {
        my $self = shift ;
        my $localEntry = shift ;

        my $filename = $localEntry->filename ;
        my $localHeaderOffset = $localEntry->localHeaderOffset;
        my $payloadOffset = $localEntry->payloadOffset ;

        my $existingEntry = $self->{byName}{$filename} ;

        my $endSurfaceArea = $payloadOffset + ($localEntry->compressedSize // 0)  ;

        if ($existingEntry)
        {
            ::error $localHeaderOffset,
                    "Duplicate Local Directory entry for filename '$filename'",
                    "Current Local Directory entry at offset " . ::decimalHex0x($localHeaderOffset),
                    "Duplicate Local Directory entry at offset " . ::decimalHex0x($existingEntry->localHeaderOffset),
        }
        else
        {

            my ($existing_filename, $offset) = $self->normalize_filename($filename);
            if ($existing_filename)
            {
                ::warning $localHeaderOffset,
                        "Portability Issue: Found case-insensitive duplicate for filename '$filename'",
                        "Current Local Directory entry at offset " . ::decimalHex0x($localHeaderOffset),
                        "Duplicate Local Directory entry for filename '$existing_filename' at offset " . ::decimalHex0x($offset);
            }
        }

        # keep nested local entries for zipbomb deteection
        push @{ $self->{entries} }, $localEntry;

        $self->{byLocalOffset}{$localHeaderOffset} = $localEntry;
        $self->{byName}{ $filename } = $localEntry;

        $self->{streamedPresent} ++
            if $localEntry->streamed;

        Nesting::add($localEntry);
    }

    sub exists
    {
        my $self = shift ;

        return scalar @{ $self->{entries} };
    }

    sub sortByLocalOffset
    {
        my $self = shift ;

        @{ $self->{entries} } = sort { $a->localHeaderOffset() <=> $b->localHeaderOffset() }
                                @{ $self->{entries} };
    }

    sub localOffset
    {
        my $self = shift ;
        my $offset = shift ;

        return $self->{byLocalOffset}{$offset} ;
    }

    sub getByLocalOffset
    {
        my $self = shift ;
        my $offset = shift ;

        # TODO - what happens if none exists?
        my $entry = $self->{byLocalOffset}{$offset} ;
        return $entry ;
    }

    sub getNextLocalOffset
    {
        my $self = shift ;
        my $offset = shift ;

        my $index = $self->{offset2Index} ;

        if ($index + 1 >= $self->{count})
        {
            return 0;
        }

        return ${ $self->{entries} }[$index+1]->localHeaderOffset ;
    }

    sub lastStreamedEntryAdded
    {
        my $self = shift ;
        my $offset = shift ;

        for my $entry ( reverse @{ $self->{entries} } )
        {
            if ($entry->streamed)# && ! $entry->streamedMatch)
            {
                $entry->streamedMatch($entry->streamedMatch + 1) ;
                return $entry;
            }
        }

        return undef;
    }

    sub inCD
    {
        my $self = shift ;
        $FH->tell() >= $self->{CentralDirectoryOffset};
    }

    sub setPkEncryptedCD
    {
        my $self = shift ;

        $self->{encryptedCD} = 1 ;

    }

    sub isEncryptedCD
    {
        my $self = shift ;
        return $self->{encryptedCD} ;
    }

    sub anyStreamedEntries
    {
        my $self = shift ;
        return $self->{streamedPresent} ;
    }

    sub normalize_filename
    {
        # check if there is a filename that already exists
        # with the same name when normalized to lower case

        my $self = shift ;
        my $filename = shift;

        my $nFilename = lc $filename;

        my $lookup = $self->{normalized_filenames}{$nFilename};
        if ($lookup && $lookup ne $filename)
        {
            return $self->{byName}{$lookup}{outputFilename},
                   $self->{byName}{$lookup}{localHeaderOffset}
        }

        $self->{normalized_filenames}{$nFilename} = $filename;

        return undef, undef;
    }
}

{
    package Eocd ;

    sub new
    {
        my $class = shift ;

        my %object = (
                        'zip64'       => 0,
                     ) ;

        bless \%object, $class;
    }
}

sub displayFileInfo
{
    return;

    my $filename = shift;

    info undef,
        "Filename       : '$filename'",
        "Size           : " . (-s $filename) . " (" . decimalHex0x(-s $filename) . ")",
        # "Native Encoding: '" . TextEncoding::getNativeLocaleName() . "'",
}

{
    package TextEncoding;

    my $nativeLocaleEncoding = getNativeLocale();
    my $opt_EncodingFrom = $nativeLocaleEncoding;
    my $opt_EncodingTo = $nativeLocaleEncoding ;
    my $opt_Encoding_Enabled;
    my $opt_Debug_Encoding;
    my $opt_use_LanguageEncodingFlag;

    sub setDefaults
    {
        $nativeLocaleEncoding = getNativeLocale();
        $opt_EncodingFrom = $nativeLocaleEncoding;
        $opt_EncodingTo = $nativeLocaleEncoding ;
        $opt_Encoding_Enabled = 1;
        $opt_Debug_Encoding = 0;
        $opt_use_LanguageEncodingFlag = 1;
    }

    sub getNativeLocale
    {
        state $enc;

        if (! defined $enc)
        {
            eval
            {
                require encoding ;
                my $encoding = encoding::_get_locale_encoding() ;
                if (! $encoding)
                {
                    # CP437 is the legacy default for zip files
                    $encoding = 'cp437';
                    # ::warning undef, "Cannot determine system charset: defaulting to '$encoding'"
                }
                $enc = Encode::find_encoding($encoding) ;
            } ;
        }

        return $enc;
    }

    sub getNativeLocaleName
    {
        state $name;

        return $name
            if defined $name ;

        if (! defined $name)
        {
            my $enc = getNativeLocale();
            if ($enc)
            {
                $name = $enc->name()
            }
            else
            {
                $name = 'unknown'
            }
        }

        return $name ;
    }

    sub parseEncodingOption
    {
        my $opt_name = shift;
        my $opt_value = shift;

        my $enc = Encode::find_encoding($opt_value) ;
        die "Encoding '$opt_value' not found for option '$opt_name'\n"
            unless ref $enc;

        if ($opt_name eq 'encoding')
        {
            $opt_EncodingFrom = $enc;
        }
        elsif ($opt_name eq 'output-encoding')
        {
            $opt_EncodingTo = $enc;
        }
        else
        {
            die "Unknown option $opt_name\n"
        }
    }

    sub NoEncoding
    {
        my $opt_name = shift;
        my $opt_value = shift;

        $opt_Encoding_Enabled = 0 ;
    }

    sub LanguageEncodingFlag
    {
        my $opt_name = shift;
        my $opt_value = shift;

        $opt_use_LanguageEncodingFlag = $opt_value ;
    }

    sub debugEncoding
    {
        if (@_)
        {
            $opt_Debug_Encoding = 1 ;
        }

        return $opt_Debug_Encoding ;
    }

    sub encodingInfo
    {
        return
            unless $opt_Encoding_Enabled && $opt_Debug_Encoding ;

        my $enc  = TextEncoding::getNativeLocaleName();
        my $from = $opt_EncodingFrom->name();
        my $to   = $opt_EncodingTo->name();

        ::debug undef, "Debug Encoding Enabled",
                      "System Default Encoding:                  '$enc'",
                      "Encoding used when reading from zip file: '$from'",
                      "Encoding used for display output:         '$to'";
    }

    sub cleanEval
    {
        chomp $_[0] ;
        $_[0] =~ s/ at .+ line \d+\.$// ;
        return $_[0];
    }

    sub decode
    {
        my $name = shift ;
        my $type = shift ;
        my $LanguageEncodingFlag = shift ;

        return $name
            if ! $opt_Encoding_Enabled ;

        # TODO - check for badly formed content
        if ($LanguageEncodingFlag && $opt_use_LanguageEncodingFlag)
        {
            # use "utf-8-strict" to catch invalid codepoints
            eval { $name = Encode::decode('utf-8-strict', $name, Encode::FB_CROAK ) } ;
            ::warning $FH->tell() - length $name, "Could not decode 'UTF-8' $type: " . cleanEval $@
                if $@ ;
        }
        else
        {
            eval { $name = $opt_EncodingFrom->decode($name, Encode::FB_CROAK ) } ;
            ::warning $FH->tell() - length $name, "Could not decode '" . $opt_EncodingFrom->name() . "' $type: " . cleanEval $@
                if $@;
        }

        # remove any BOM
        $name =~ s/^\x{FEFF}//;

        return $name ;
    }

    sub encode
    {
        my $name = shift ;
        my $type = shift ;
        my $LanguageEncodingFlag = shift ;

        return $name
            if ! $opt_Encoding_Enabled;

        if ($LanguageEncodingFlag && $opt_use_LanguageEncodingFlag)
        {
            eval { $name = Encode::encode('utf8', $name, Encode::FB_CROAK ) } ;
            ::warning $FH->tell() - length $name, "Could not encode 'utf8' $type: " . cleanEval $@
                if $@ ;
        }
        else
        {
            eval { $name = $opt_EncodingTo->encode($name, Encode::FB_CROAK ) } ;
            ::warning $FH->tell() - length $name, "Could not encode '" . $opt_EncodingTo->name() . "' $type: " . cleanEval $@
                if $@;
        }

        return $name;
    }
}

{
    package Nesting;

    use Data::Dumper;

    my @nestingStack = ();
    my %encapsulations;
    my %inner2outer;
    my $encapsulationCount  = 0;
    my %index2entry ;
    my %offset2entry ;

    # my %localOffset2cdEntry;

    sub clearStack
    {
        @nestingStack = ();
        %encapsulations = ();
        %inner2outer = ();
        %index2entry = ();
        %offset2entry = ();
        $encapsulationCount = 0;
    }

    sub dump
    {
        my $indent = shift // 0;

        for my $offset (sort {$a <=> $b} keys %offset2entry)
        {
            my $leading = " " x $indent ;
            say $leading . "\nOffset $offset" ;
            say Dumper($offset2entry{$offset})
        }
    }

    sub add
    {
        my $entry = shift;

        getEnclosingEntry($entry);
        push @nestingStack, $entry;
        $index2entry{ $entry->index } = $entry;
        $offset2entry{ $entry->offsetStart } = $entry;
    }

    sub getEnclosingEntry
    {
        my $entry = shift;

        my $filename = $entry->filename;

        pop @nestingStack
            while @nestingStack && $entry->offsetStart > $nestingStack[-1]->offsetEnd ;

        my $match = undef;

        if (@nestingStack &&
            $entry->offsetStart >= $nestingStack[-1]->offsetStart &&
            $entry->offsetEnd   <= $nestingStack[-1]->offsetEnd &&
            $entry->index       != $nestingStack[-1]->index)
        {
            # Nested entry found
            $match = $nestingStack[-1];
            push @{ $encapsulations{ $match->index } }, $entry;
            $inner2outer{ $entry->index} = $match->index;
            ++ $encapsulationCount;

            $entry->encapsulated(1) ;
            $match->increment_childrenCount();

            if ($NESTING_DEBUG)
            {
                say "#### nesting " . (caller(1))[3] . " index #" . $entry->index . ' "' .
                    $entry->outputFilename . '" [' . $entry->offsetStart . "->" . $entry->offsetEnd . "]" .
                    " in #" . $match->index . ' "' .
                    $match->outputFilename . '" [' . $match->offsetStart . "->" . $match->offsetEnd . "]" ;
            }
        }

        return $match;
    }

    sub isNested
    {
        my $offsetStart = shift;
        my $offsetEnd = shift;

        if ($NESTING_DEBUG)
        {
            say "### Want: offsetStart " . ::decimalHex0x($offsetStart) . " offsetEnd " . ::decimalHex0x($offsetEnd);
            for my $entry (@nestingStack)
            {
                say "### Have: offsetStart " . ::decimalHex0x($entry->offsetStart) . " offsetEnd " . ::decimalHex0x($entry->offsetEnd);
            }
        }

        return 0
            unless @nestingStack ;

        my @copy = @nestingStack ;

        pop @copy
            while @copy && $offsetStart > $copy[-1]->offsetEnd ;

        return @copy &&
               $offsetStart >= $copy[-1]->offsetStart &&
               $offsetEnd   <= $copy[-1]->offsetEnd ;
    }

    sub getOuterEncapsulation
    {
        my $entry = shift;

        my $outerIndex =  $inner2outer{ $entry->index } ;

        return undef
            if ! defined $outerIndex ;

        return $index2entry{$outerIndex} // undef;
    }

    sub getEncapsulations
    {
        my $entry = shift;

        return $encapsulations{ $entry->index } ;
    }

    sub getFirstEncapsulation
    {
        my $entry = shift;

        my $got = $encapsulations{ $entry->index } ;

        return defined $got ? $$got[0] : undef;
    }

    sub encapsulations
    {
        return \%encapsulations;
    }

    sub encapsulationCount
    {
        return $encapsulationCount;
    }

    sub childrenInCentralDir
    {
        # find local header entries that have children that are not referenced in the CD
        # tis means it is likely a benign nextd zip file
        my $entry = shift;

        for my $child (@{ $encapsulations{$entry->index} } )
        {
            next
                unless $child->entryType == ::ZIP_LOCAL_HDR_SIG ;

            return 1
                if @{ $child->cdEntryList };
        }

        return 0;
    }

    sub entryByIndex
    {
        my $index = shift;
        return $index2entry{$index};
    }

    sub getEntryByOffset
    {
        my $offset  = shift;
        return $offset2entry{$offset};
    }

    sub getLdEntryByOffset
    {
        my $offset  = shift;
        my $entry = $offset2entry{$offset};

        return $entry
            if $entry && $entry->entryType == ::ZIP_LOCAL_HDR_SIG;

        return undef;
    }

    sub getEntriesByOffset
    {
        return \%offset2entry ;
    }
}

{
    package SimpleTable ;

    use List::Util qw(max sum);

    sub new
    {
        my $class = shift;

        my %object = (
            header => [],
            data   => [],
            columns   => 0,
            prefix => '#  ',
        );
        bless \%object, $class;
    }

    sub addHeaderRow
    {
        my $self = shift;
        push @{ $self->{header} }, [ @_ ] ;
        $self->{columns} = max($self->{columns}, scalar @_ ) ;
    }

    sub addDataRow
    {
        my $self = shift;

        push @{ $self->{data} }, [ @_ ] ;
        $self->{columns} = max($self->{columns}, scalar @_ ) ;
    }

    sub hasData
    {
        my $self = shift;

        return scalar @{ $self->{data} } ;
    }

    sub display
    {
        my $self = shift;

        # work out the column widths
        my @colW = (0) x $self->{columns} ;
        for my $row (@{ $self->{data} }, @{ $self->{header} })
        {
            my @r = @$row;
            for my $ix (0 .. $self->{columns} -1)
            {
                $colW[$ix] = max($colW[$ix],
                                3 + length( $r[$ix] )
                                );
            }
        }

        my $width = sum(@colW) ; #+ @colW ;
        my @template ;
        for my $w (@colW)
        {
            push @template, ' ' x ($w - 3);
        }

        print $self->{prefix} . '-' x ($width + 1) . "\n";

        for my $row (@{ $self->{header} })
        {
            my @outputRow = @template;

            print $self->{prefix} . '| ';
            for my $ix (0 .. $self->{columns} -1)
            {
                my $field = $template[$ix] ;
                substr($field, 0, length($row->[$ix]), $row->[$ix]);
                print $field . ' | ';
            }
            print "\n";

        }

        print $self->{prefix} . '-' x ($width + 1) . "\n";

        for my $row (@{ $self->{data} })
        {
            my @outputRow = @template;

            print $self->{prefix} . '| ';
            for my $ix (0 .. $self->{columns} -1)
            {
                my $field = $template[$ix] ;
                substr($field, 0, length($row->[$ix]), $row->[$ix]);
                print $field . ' | ';
            }
            print "\n";
        }

        print $self->{prefix} . '-' x ($width + 1) . "\n";
        print "#\n";
    }
}

sub Usage
{
    my $enc = TextEncoding::getNativeLocaleName();

    my $message = <<EOM;
zipdetails [OPTIONS] file

Display details about the internal structure of a Zip file.

OPTIONS

  General Options
     -h, --help
            Display help
     --redact
            Hide filename and payload data in the output
     --scan
            Enable pessimistic scanning mode.
            Blindly scan the file looking for zip headers
            Expect false-positives.
     --utc
            Display date/time fields in UTC. Default is local time
     -v
            Enable verbose mode -- output more stuff
     --version
            Print zipdetails version number
            This is version $VERSION
     --walk
            Enable optimistic scanning mode.
            Blindly scan the file looking for zip headers
            Expect false-positives.

  Filename/Comment Encoding
    --encoding e
            Use encoding "e" when reading filename/comments from the zip file
            Uses system encoding ('$enc') by default
    --no-encoding
            Disable filename & comment encoding. Default disabled.
    --output-encoding e
            Use encoding "e" when writing filename/comments to the display
            Uses system encoding ('$enc') by default
    --debug-encoding
            Display eatra info when a filename/comment encoding has changed
    --language-encoding, --no-language-encoding
            Enable/disable support for the zip file "Language Encoding" flag.
            When this flag is set in a zip file the filename/comment is assumed
            to be encoded in UTF8.
            Default is enabled

  Message Control
     --messages, --no-messages
            Enable/disable all info/warning/error messages. Default enabled.
     --exit-bitmask, --no-exit-bitmask
            Enable/disable exit status bitmask for messages. Default disabled.
            Bitmask values are
                Info    1
                Warning 2
                Error   4

Copyright (c) 2011-2024 Paul Marquess. All rights reserved.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.
EOM

    if (@_)
    {
        warn "$_\n"
            for @_  ;
        warn "\n";

        die $message ;
    }

    print $message ;
    exit 0;

}

1;

__END__

=head1 NAME

zipdetails - display the internal structure of zip files

=head1 SYNOPSIS

    zipdetails [options] zipfile.zip

=head1 DESCRIPTION

This program creates a detailed report on the internal structure of zip
files. For each item of metadata within a zip file the program will output

=over 5

=item the offset into the zip file where the item is located.

=item a textual representation for the item.

=item an optional hex dump of the item.

=back


The program assumes a prior understanding of the internal structure of Zip
files. You should have a copy of the zip file definition,
L<APPNOTE.TXT|https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT>,
at hand to help understand the output from this program.

=head2 Default Behaviour

By default the program expects to be given a well-formed zip file.  It will
navigate the zip file by first parsing the zip C<Central Directory> at the end
of the file.  If the C<Central Directory> is found, it will then walk
sequentally through the zip records starting at the beginning of the file.
See L<Advanced Analysis> for other processing options.

If the program finds any structural or portability issues with the zip file
it will print a message at the point it finds the issue and/or in a summary
at the end of the output report. Whilst the set of issues that can be
detected it exhaustive, don't assume that this program can find I<all> the
possible issues in a zip file - there are likely edge conditions that need
to be addressed.

If you have suggestions for use-cases where this could be enhanced please
consider creating an enhancement request (see L<"SUPPORT">).

=head3 Date & Time fields

Date/time fields found in zip files are displayed in local time. Use the
C<--utc> option to display these fields in Coordinated Universal Time (UTC).

=head3 Filenames & Comments

Filenames and comments are decoded/encoded using the default system
encoding of the host running C<zipdetails>. When the sytem encoding cannot
be determined C<cp437> will be used.

The exceptions are

=over 5

=item *

when the C<Language Encoding Flag> is set in the zip file, the
filename/comment fields are assumed to be encoded in UTF-8.

=item *

the definition for the metadata field implies UTF-8 charset encoding

=back

See L<"Filename Encoding Issues"> and L<Filename & Comment Encoding
Options> for ways to control the encoding of filename/comment fields.

=head2 OPTIONS

=head3 General Options

=over 5

=item C<-h>, C<--help>

Display help

=item C<--redact>

Obscure filenames and payload data in the output. Handy for the use case
where the zip files contains sensitive data that cannot be shared.

=item C<--scan>

Pessimistically scan the zip file loking for possible zip records. Can be
error-prone. For very large zip files this option is slow. Consider using
the C<--walk> option first. See L<"Advanced Analysis Options">

=item C<--utc>

By default, date/time fields are displayed in local time. Use this option to
display them in in Coordinated Universal Time (UTC).

=item C<-v>

Enable Verbose mode. See L<"Verbose Output">.

=item C<--version>

Display version number of the program and exit.

=item C<--walk>

Optimistically walk the zip file looking for possible zip records.
See L<"Advanced Analysis Options">

=back

=head3 Filename & Comment Encoding Options

See L<"Filename Encoding Issues">

=over 5

=item C<--encoding name>

Use encoding "name" when reading filenames/comments from the zip file.

When this option is not specified the default the system encoding is used.

=item C< --no-encoding>

Disable all filename & comment encoding/decoding. Filenames/comments are
processed as byte streams.

This option is not enabled by default.

=item C<--output-encoding name>

Use encoding "name" when writing filename/comments to the display.  By
default the system encoding will be used.

=item C<--language-encoding>, C<--no-language-encoding>

Modern zip files set a metadata entry in zip files, called the "Language
encoding flag", when they write filenames/comments encoded in UTF-8.

Occasionally some applications set the C<Language Encoding Flag> but write
data that is not UTF-8 in the filename/comment fields of the zip file. This
will usually result in garbled text being output for the
filenames/comments.

To deal with this use-case, set the C<--no-language-encoding> option and,
if needed, set the C<--encoding name> option to encoding actually used.

Default is C<--language-encoding>.

=item C<--debug-encoding>

Display extra debugging info when a filename/comment encoding has changed.

=back

=head3 Message Control Options

=over 5

=item C<--messages>, C<--no-messages>

Enable/disable the output of all info/warning/error messages.

Disabling messages means that no checks are carried out to check that the
zip file is well-formed.

Default is enabled.

=item C<--exit-bitmask>, C<--no-exit-bitmask>

Enable/disable exit status bitmask for messages. Default disabled.
Bitmask values are: 1 for info, 2 for warning and 4 for error.

=back


=head2 Default Output

By default C<zipdetails> will output each metadata field from the zip file
in three columns.

=over 5

=item 1

The offset, in hex, to the start of the field relative to the beginning of
the file.

=item 2

The name of the field.

=item 3

Detailed information about the contents of the field. The format depends on
the type of data:

=over 5

=item * Numeric Values

If the field contains an 8-bit, 16-bit, 32-bit or 64-bit numeric value, it
will be displayed in both hex and decimal -- for example "C<002A (42)>".

Note that Zip files store most numeric values in I<little-endian> encoding
(there area few rare instances where I<big-endian> is used). The value read
from the zip file will have the I<endian> encoding removed before being
displayed.

Next, is an optional description of what the numeric value means.

=item * String

If the field corresponds to a printable string, it will be output enclosed
in single quotes.

=item * Binary Data

The term I<Binary Data> is just a catch-all for all other metadata in the
zip file. This data is displayed as a series of ascii-hex byte values in
the same order they are stored in the zip file.

=back

=back

For example, assuming you have a zip file, C<test,zip>, with one entry

    $ unzip -l  test.zip
    Archive:  test.zip
    Length      Date    Time    Name
    ---------  ---------- -----   ----
        446  2023-03-22 20:03   lorem.txt
    ---------                     -------
        446                     1 file

Running C<zipdetails> will gives this output

    $ zipdetails test.zip

    0000 LOCAL HEADER #1       04034B50 (67324752)
    0004 Extract Zip Spec      14 (20) '2.0'
    0005 Extract OS            00 (0) 'MS-DOS'
    0006 General Purpose Flag  0000 (0)
         [Bits 1-2]            0 'Normal Compression'
    0008 Compression Method    0008 (8) 'Deflated'
    000A Modification Time     5676A072 (1450614898) 'Wed Mar 22 20:03:36 2023'
    000E CRC                   F90EE7FF (4178503679)
    0012 Compressed Size       0000010E (270)
    0016 Uncompressed Size     000001BE (446)
    001A Filename Length       0009 (9)
    001C Extra Length          0000 (0)
    001E Filename              'lorem.txt'
    0027 PAYLOAD

    0135 CENTRAL HEADER #1     02014B50 (33639248)
    0139 Created Zip Spec      1E (30) '3.0'
    013A Created OS            03 (3) 'Unix'
    013B Extract Zip Spec      14 (20) '2.0'
    013C Extract OS            00 (0) 'MS-DOS'
    013D General Purpose Flag  0000 (0)
         [Bits 1-2]            0 'Normal Compression'
    013F Compression Method    0008 (8) 'Deflated'
    0141 Modification Time     5676A072 (1450614898) 'Wed Mar 22 20:03:36 2023'
    0145 CRC                   F90EE7FF (4178503679)
    0149 Compressed Size       0000010E (270)
    014D Uncompressed Size     000001BE (446)
    0151 Filename Length       0009 (9)
    0153 Extra Length          0000 (0)
    0155 Comment Length        0000 (0)
    0157 Disk Start            0000 (0)
    0159 Int File Attributes   0001 (1)
         [Bit 0]               1 'Text Data'
    015B Ext File Attributes   81ED0000 (2179792896)
         [Bits 16-24]          01ED (493) 'Unix attrib: rwxr-xr-x'
         [Bits 28-31]          08 (8) 'Regular File'
    015F Local Header Offset   00000000 (0)
    0163 Filename              'lorem.txt'

    016C END CENTRAL HEADER    06054B50 (101010256)
    0170 Number of this disk   0000 (0)
    0172 Central Dir Disk no   0000 (0)
    0174 Entries in this disk  0001 (1)
    0176 Total Entries         0001 (1)
    0178 Size of Central Dir   00000037 (55)
    017C Offset to Central Dir 00000135 (309)
    0180 Comment Length        0000 (0)
    #
    # Done


=head2 Verbose Output

If the C<-v> option is present, the metadata output is split into the
following columns:

=over 5

=item 1

The offset, in hex, to the start of the field relative to the beginning of
the file.

=item 2

The offset, in hex, to the end of the field relative to the beginning of
the file.

=item 3

The length, in hex, of the field.

=item 4

A hex dump of the bytes in field in the order they are stored in the zip file.

=item 5

A textual description of the field.

=item 6

Information about the contents of the field. See the description in the
L<Default Output> for more details.

=back

Here is the same zip file, C<test.zip>, dumped using the C<zipdetails>
C<-v> option:

    $ zipdetails -v test.zip

    0000 0003 0004 50 4B 03 04 LOCAL HEADER #1       04034B50 (67324752)
    0004 0004 0001 14          Extract Zip Spec      14 (20) '2.0'
    0005 0005 0001 00          Extract OS            00 (0) 'MS-DOS'
    0006 0007 0002 00 00       General Purpose Flag  0000 (0)
                               [Bits 1-2]            0 'Normal Compression'
    0008 0009 0002 08 00       Compression Method    0008 (8) 'Deflated'
    000A 000D 0004 72 A0 76 56 Modification Time     5676A072 (1450614898) 'Wed Mar 22 20:03:36 2023'
    000E 0011 0004 FF E7 0E F9 CRC                   F90EE7FF (4178503679)
    0012 0015 0004 0E 01 00 00 Compressed Size       0000010E (270)
    0016 0019 0004 BE 01 00 00 Uncompressed Size     000001BE (446)
    001A 001B 0002 09 00       Filename Length       0009 (9)
    001C 001D 0002 00 00       Extra Length          0000 (0)
    001E 0026 0009 6C 6F 72 65 Filename              'lorem.txt'
                   6D 2E 74 78
                   74
    0027 0134 010E ...         PAYLOAD

    0135 0138 0004 50 4B 01 02 CENTRAL HEADER #1     02014B50 (33639248)
    0139 0139 0001 1E          Created Zip Spec      1E (30) '3.0'
    013A 013A 0001 03          Created OS            03 (3) 'Unix'
    013B 013B 0001 14          Extract Zip Spec      14 (20) '2.0'
    013C 013C 0001 00          Extract OS            00 (0) 'MS-DOS'
    013D 013E 0002 00 00       General Purpose Flag  0000 (0)
                               [Bits 1-2]            0 'Normal Compression'
    013F 0140 0002 08 00       Compression Method    0008 (8) 'Deflated'
    0141 0144 0004 72 A0 76 56 Modification Time     5676A072 (1450614898) 'Wed Mar 22 20:03:36 2023'
    0145 0148 0004 FF E7 0E F9 CRC                   F90EE7FF (4178503679)
    0149 014C 0004 0E 01 00 00 Compressed Size       0000010E (270)
    014D 0150 0004 BE 01 00 00 Uncompressed Size     000001BE (446)
    0151 0152 0002 09 00       Filename Length       0009 (9)
    0153 0154 0002 00 00       Extra Length          0000 (0)
    0155 0156 0002 00 00       Comment Length        0000 (0)
    0157 0158 0002 00 00       Disk Start            0000 (0)
    0159 015A 0002 01 00       Int File Attributes   0001 (1)
                               [Bit 0]               1 'Text Data'
    015B 015E 0004 00 00 ED 81 Ext File Attributes   81ED0000 (2179792896)
                               [Bits 16-24]          01ED (493) 'Unix attrib: rwxr-xr-x'
                               [Bits 28-31]          08 (8) 'Regular File'
    015F 0162 0004 00 00 00 00 Local Header Offset   00000000 (0)
    0163 016B 0009 6C 6F 72 65 Filename              'lorem.txt'
                   6D 2E 74 78
                   74

    016C 016F 0004 50 4B 05 06 END CENTRAL HEADER    06054B50 (101010256)
    0170 0171 0002 00 00       Number of this disk   0000 (0)
    0172 0173 0002 00 00       Central Dir Disk no   0000 (0)
    0174 0175 0002 01 00       Entries in this disk  0001 (1)
    0176 0177 0002 01 00       Total Entries         0001 (1)
    0178 017B 0004 37 00 00 00 Size of Central Dir   00000037 (55)
    017C 017F 0004 35 01 00 00 Offset to Central Dir 00000135 (309)
    0180 0181 0002 00 00       Comment Length        0000 (0)
    #
    # Done

=head2 Advanced Analysis

If you have a corrupt or non-standard zip file, particulatly one where the
C<Central Directory> metadata at the end of the file is absent/incomplete, you
can use either the C<--walk> option or the C<--scan> option to search for
any zip metadata that is still present in the file.

When either of these options is enabled, this program will bypass the
initial step of reading the C<Central Directory> at the end of the file and
simply scan the zip file sequentially from the start of the file looking
for zip metedata records. Although this can be error prone, for the most
part it will find any zip file metadata that is still present in the file.

The difference between the two options is how aggressive the sequential
scan is: C<--walk> is optimistic, while C<--scan> is pessimistic.

To understand the difference in more detail you need to know a bit about
how zip file metadata is structured. Under the hood, a zip file uses a
series of 4-byte signatures to flag the start of a each of the metadata
records it uses. When the C<--walk> or the C<--scan> option is enabled both
work identically by scanning the file from the beginning looking for any
the of these valid 4-byte metadata signatures. When a 4-byte signature is
found both options will blindly assume that it has found a vald metadata
record and display it.

=head3 C<--walk>

The C<--walk> option optimistically assumes that it has found a real zip
metatada record and so starts the scan for the next record directly after
the record it has just output.

=head3 C<--scan>

The C<--scan> option is pessimistic and assumes the 4-byte signature
sequence may have been a false-positive, so before starting the scan for
the next resord, it will rewind to the location in the file directly after
the 4-byte sequecce it just processed. This means it will rescan data that
has already been processed.  For very lage zip files the C<--scan> option
can be really realy slow, so trying the C<--walk> option first.

B<Important Note>: If the zip file being processed contains one or more
nested zip files, and the outer zip file uses the C<STORE> compression
method, the C<--scan> option will display the zip metadata for both the
outer & inner zip files.

=head2 Filename Encoding Issues

Sometimes when displaying the contents of a zip file the filenames (or
comments) appear to be garbled. This section walks through the reasons and
mitigations that can be applied to work around these issues.

=head3 Background

When zip files were first created in the 1980's, there was no Unicode or
UTF-8. Issues around character set encoding interoperability were not a
major concern.

Initially, the only official encoding supported in zip files was IBM Code
Page 437 (AKA C<CP437>). As time went on users in locales where C<CP437>
wasn't appropriate stored filenames in the encoding native to their locale.
If you were running a system that matched the locale of the zip file, all
was well. If not, you had to post-process the filenames after unzipping the
zip file.

Fast forward to the introduction of Unicode and UTF-8 encoding. The
approach now used by all major zip implementations is to set the C<Language
encoding flag> (also known as C<EFS>) in the zip file metadata to signal
that a filename/comment is encoded in UTF-8.

To ensure maximum interoperability when sharing zip files store 7-bit
filenames as-is in the zip file. For anything else the C<EFS> bit needs to
be set and the filename is encoded in UTF-8. Although this rule is kept to
for the most part, there are exceptions out in the wild.

=head3 Dealing with Encoding Errors

The most common filename encoding issue is where the C<EFS> bit is not set and
the filename is stored in a character set that doesnt't match the system
encoding. This mostly impacts legacy zip files that predate the
introduction of Unicode.

To deal with this issue you first need to know what encoding was used in
the zip file. For example, if the filename is encoded in C<ISO-8859-1> you
can display the filenames using the C<--encoding> option

    zipdetails --encoding ISO-8859-1 myfile.zip

A less common variation of this is where the C<EFS> bit is set, signalling
that the filename will be encoded in UTF-8, but the filename is not encoded
in UTF-8. To deal with this scenarion, use the C<--no-language-encoding>
option along with the C<--encoding> option.


=head1 LIMITATIONS

The following zip file features are not supported by this program:

=over 5

=item *

Multi-part/Split/Spanned Zip Archives.

This program cannot give an overall report on the combined parts of a
multi-part zip file.

The best you can do is run with either the C<--scan> or C<--walk> options
against individual parts. Some will contains zipfile metadata which will be
detected and some will only contain compressed payload data.


=item *

Encrypted Central Directory

When pkzip I<Strong Encryption> is enabled in a zip file this program can
still parse most of the metadata in the zip file. The exception is when the
C<Central Directory> of a zip file is also encrypted. This program cannot
parse any metadata from an encrypted C<Central Directory>.

=item *

Corrupt Zip files

When C<zipdetails> encounters a corrupt zip file, it will do one or more of
the following

=over 5

=item *

Display details of the corruption and carry on

=item *

Display details of the corruption and terminate

=item *

Terminate with a generic message

=back

Which of the above is output is dependent in the severity of the
corruption.

=back

=head1 TODO

=head2 JSON/YML Output

Output some of the zip file metadata as a JSON or YML document.

=head2 Corrupt Zip files

Although the detection and reporting of most of the common corruption use-cases is
present in C<zipdetails>, there are likely to be other edge cases that need
to be supported.

If you have a corrupt Zip file that isn't being processed properly, please
report it (see  L<"SUPPORT">).

=head1 SUPPORT

General feedback/questions/bug reports should be sent to
L<https://github.com/pmqs/zipdetails/issues>.

=head1 SEE ALSO


The primary reference for Zip files is
L<APPNOTE.TXT|https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT>.

An alternative reference is the Info-Zip appnote. This is available from
L<ftp://ftp.info-zip.org/pub/infozip/doc/>

For details of WinZip AES encryption see L<AES Encryption Information:
Encryption Specification AE-1 and
AE-2|https://www.winzip.com/en/support/aes-encryption/>.

The C<zipinfo> program that comes with the info-zip distribution
(L<http://www.info-zip.org/>) can also display details of the structure of a zip
file.


=head1 AUTHOR

Paul Marquess F<pmqs@cpan.org>.

=head1 COPYRIGHT

Copyright (c) 2011-2024 Paul Marquess. All rights reserved.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.
