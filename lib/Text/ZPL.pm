package Text::ZPL;
$Text::ZPL::VERSION = '0.001002';
use strict; use warnings FATAL => 'all';

use Carp;
use Scalar::Util 'blessed', 'reftype';

use parent 'Exporter::Tiny';
our @EXPORT = our @EXPORT_OK = qw/
  encode_zpl
  decode_zpl
/;

# FIXME streaming interface?

# note: not anchored as-is:
our $ValidName = qr/[A-Za-z0-9\$\-_\@.&+\/]+/;

sub decode_zpl {
  my ($str) = @_;

  my @lines = split /(?:\r?\n)|\r/, $str;

  my $root = +{};
  my $ref  = $root;
  my @descended;

  my $level   = 0;
  my $lineno  = 0;

  LINE: for my $line (@lines) {
    ++$lineno;
    # Trim trailing WS + skip blank/comments-only:
    $line =~ s/\s+$//;
    next LINE if length($line) == 0 or $line =~ /^(?:\s+)?#/;

    # Manage indentation-based hierarchy:
    my $cur_indent = 0;
    $cur_indent++ while substr($line, $cur_indent, 1) eq ' ';
    if ($cur_indent % 4) {
      confess
         "Invalid ZPL (line $lineno); "
        ."expected 4-space indent, indent is $cur_indent"
    }

    if ($cur_indent == 0) {
      $ref = $root;
      @descended = ();
      $level = 0;
    } elsif ($cur_indent > $level) {
      unless (defined $descended[ ($cur_indent / 4) - 1 ]) {
        confess "Invalid ZPL (line $lineno); no matching parent section",
          " [$line]"
      }
      $level = $cur_indent; 
    } elsif ($cur_indent < $level) {
      my $wanted_idx = ( ($level - $cur_indent) / 4 ) - 1 ;
      my $wanted_ref = $descended[$wanted_idx];
      unless (defined $wanted_ref) {
        confess
          "BUG; cannot find matching parent section"
          ." [idx = $wanted_idx] [indent = $cur_indent]"
      }
      $ref = $wanted_ref;
      my $startidx = $wanted_idx + 1;
      @descended = @descended[$startidx .. $#descended];
      $level = $cur_indent;
    }

    # KV pair:
    if ( (my $sep_pos = index($line, '=')) > 0 ) {
      my $key = substr $line, $level, ( $sep_pos - $level );
      $key =~ s/\s+$//;
      unless ($key =~ /^$ValidName$/) {
        confess "Invalid ZPL (line $lineno); "
                ."'$key' is not a valid ZPL property name"
      }

      my $realval;
      my $tmpval = substr $line, $sep_pos + 1;
      $tmpval =~ s/^\s+//;

      my $maybe_q = substr $tmpval, 0, 1;
      undef $maybe_q unless $maybe_q eq q{'} or $maybe_q eq q{"};

      if ( defined $maybe_q 
        && (my $matching_q_pos = index $tmpval, $maybe_q, 1) > 1 ) {
        # Quoted, consume up to matching and clean up tmpval
        $realval = substr $tmpval, 1, ($matching_q_pos - 1), '';
        substr $tmpval, 0, 2, '' if substr($tmpval, 0, 2) eq $maybe_q x 2;
      } else {
        # Unquoted or mismatched quotes
        my $maybe_trailing = index $tmpval, ' ';
        $maybe_trailing = length $tmpval unless $maybe_trailing > -1;
        $realval = substr $tmpval, 0, $maybe_trailing, '';
      }

      $tmpval =~ s/#.*$//; $tmpval =~ s/\s+//;
      # Should've thrown away usable pieces by now:
      if (length $tmpval) {
        confess "Invalid ZPL (line $lineno); garbage at end-of-line '$tmpval'"
      }

      if (exists $ref->{$key}) {
        if (ref $ref->{$key} eq 'HASH') {
          confess
            "Invalid ZPL (line $lineno); existing subsection with this name"
        } elsif (ref $ref->{$key} eq 'ARRAY') {
          push @{ $ref->{$key} }, $realval
        } else {
          my $oldval = $ref->{$key};
          $ref->{$key} = [ $oldval, $realval ]
        }
      } else {
        $ref->{$key} = $realval
      }

      next LINE
    }

    # New subsection:
    if (my ($subsect) = $line =~ /^(?:\s+)?($ValidName)(?:\s+?#.*)?$/) {
      if (exists $ref->{$subsect}) {
        confess "Invalid ZPL (line $lineno); existing property with this name"
      }
      my $new_ref = ($ref->{$subsect} = +{});
      unshift @descended, $ref;
      $ref = $new_ref;
      next LINE
    }

    confess
       "Invalid ZPL (line $lineno); "
      ."unrecognized syntax or bad section name: '$line'"
  } # LINE

  $root
}


sub encode_zpl {
  my ($obj) = @_;
  $obj = $obj->TO_ZPL if blessed $obj and $obj->can('TO_ZPL');
  confess "Expected a HASH but got $obj" unless ref $obj eq 'HASH';
  _encode($obj)
}

sub _encode {
  my ($ref, $indent) = @_;
  $indent ||= 0;
  my $str = '';

  KEY: for my $key (keys %$ref) {
    confess "$key is not a valid ZPL property name"
      unless $key =~ qr/^$ValidName$/;
    my $val = $ref->{$key};
    
    if (blessed $val && $val->can('TO_ZPL')) {
      $val = $val->TO_ZPL;
    }

    if (ref $val eq 'ARRAY') {
      $str .= _encode_array($key, $val, $indent);
      next KEY
    }

    if (ref $val eq 'HASH') {
      $str .= ' ' x $indent;
      $str .= "$key\n";
      $str .= _encode($val, $indent + 4);
      next KEY
    }
    
    if (ref $val) {
      confess "Do not know how to handle '$val'"
    }

    $str .= ' ' x $indent;
    $str .= "$key = " . _maybe_quote($val) . "\n";
  }

  $str
}

sub _encode_array {
  my ($key, $ref, $indent) = @_;
  my $str;
  for my $item (@$ref) {
    confess "ZPL does not support structures of this type in lists: ".ref $item
      if ref $item;
    $str .= ' ' x $indent;
    $str .= "$key = " . _maybe_quote($item) . "\n";
  }
  $str
}

sub _maybe_quote {
  my ($val) = @_;
  return qq{'$val'}
    if index($val, q{"}) > -1
    and index($val, q{'}) == -1;
  return qq{"$val"}
    # FIXME ? doesn't handle tabs:
    if index($val, ' ')  > -1
    or index($val, '#')  > -1
    or index($val, q{'}) > -1 and index($val, q{"}) == -1;
  $val
}

1;

=pod

=head1 NAME

Text::ZPL - Encode and decode ZeroMQ Property Language

=head1 SYNOPSIS

  # Decode ZPL to a HASH:
  my $data = decode_zpl( $zpl_text );
  # Encode a HASH to ZPL text:
  my $zpl = encode_zpl( $data );

=head1 DESCRIPTION

An implementation of the C<ZeroMQ Property Language>, a simple ASCII
configuration file format; see L<http://rfc.zeromq.org/spec:4> for details.

As a simple example, a C<ZPL> file as such:

  # This is my conf.
  # There are many like it, but this one is mine.
  confname = "My Config"

  context
      iothreads = 1

  main
      publisher
          bind = tcp://eth0:5550
          bind = tcp://eth0:5551
      subscriber
          connect = tcp://192.168.0.10:5555

... results in a structure like:

  {
    confname => "My Config",
    context => { iothreads => '1' },
    main => {
      subscriber => {
        connect => 'tcp://192.168.0.10:5555'
      },
      publisher => {
        bind => [ 'tcp://eth0:5550', 'tcp://eth0:5551' ]
      }
    }
  }

=head2 decode_zpl

Given a string of C<ZPL>-encoded text, returns an appropriate Perl C<HASH>; an
exception is thrown if invalid input is encountered.

=head2 encode_zpl

Given a Perl C<HASH>, returns an appropriate C<ZPL>-encoded text string; an
exception is thrown if the data given cannot be represented in C<ZPL> (see
L</CAVEATS>).

=head3 TO_ZPL

A blessed object can provide a B<TO_ZPL> method that will supply a plain
C<HASH> or C<ARRAY> (but see L</CAVEATS>) to the encoder:

  # Shallow-clone our backing hash, for example:
  sub TO_ZPL {
    my $self = shift;
    +{ %$self }
  }

=head2 CAVEATS

Not all Perl data structures can be represented in ZPL; specifically,
deeply-nested structures in an C<ARRAY> will throw an exception:

  # Simple list is OK:
  encode_zpl(+{ list => [ 1 .. 3 ] });
  #  -> list: 1
  #     list: 2
  #     list: 3
  # Deeply nested is not representable:
  encode_zpl(+{
    list => [
      'abc',
      list2 => [1 .. 3]
    ],
  });
  #  -> dies

=head1 AUTHOR

Jon Portnoy <avenj@cobaltirc.org>

=cut
