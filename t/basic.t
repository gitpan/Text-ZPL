use Test::More;
use strict; use warnings FATAL => 'all';


use Text::ZPL;

my $basic = do {; local $/; <DATA> };

my $data = decode_zpl($basic);
is_deeply $data,
  +{
    toplevel  => 123,
    quoted    => 'foo bar',
    unmatched => q{"foo'},

    context => +{
      iothreads => 1,
      verbose   => 1,
    },

    main => +{
      type => 'zmq_queue',
      frontend => +{
        option => +{
          hwm  => 1000,
          swap => '25000000',
          subscribe => '#2',
        },
        bind => 'tcp://eth0:5555',
      },
      backend => +{
        bind => 'tcp://eth0:5556',
      },
    },

    emptysection => +{},

    other => +{
      list => [
        'foo bar', 'baz quux', 'weeble'
      ],
      deeper => +{
        list2 => [ 123, 456 ],
      },
    },
  },
  'decode_zpl ok';

my $reencoded = encode_zpl $data;

my $roundtripped = decode_zpl $reencoded;
is_deeply $roundtripped, $data, 'roundtripped ok';


my $mixed_newlines = "foo=1\015\012bar=2\012baz=3\015quux=weeble\n";
my $mixed_decoded  = decode_zpl $mixed_newlines;
is_deeply $mixed_decoded,
  +{
    foo => 1, bar => 2, baz => 3, quux => 'weeble'
  },
  'mixed newlines ok';

my $with_empty_arrayref = +{
  foo => [],
};
my $empty_arrayref_rtrip = decode_zpl( encode_zpl $with_empty_arrayref );
is_deeply $empty_arrayref_rtrip,
  +{ },
  'empty arrayref skipped ok';

# FIXME tests for encoding w/ various types of whitespace/specials in values

done_testing;

__DATA__
toplevel = 123
quoted   = "foo bar"
unmatched = "foo'
# There's a comment here
# and here

context #
    iothreads = 1   # With trailing comment
    verbose   = 1 #

main                # Section head with trailing comment
    type = zmq_queue
    frontend
        option
            hwm  = 1000
            swap = 25000000
            subscribe = "#2"
        bind = tcp://eth0:5555
    backend
        bind = tcp://eth0:5556

emptysection

other
    list = "foo bar"
    list = 'baz quux'  #
    list = weeble
    deeper
        list2 = 123
        list2 = 456
