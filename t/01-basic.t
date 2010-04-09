use MooseX::Declare;
use Test::More;
use File::Temp('tempfile');
use Text::Lorem;
use POE;
use IO::All;
use warnings;
use strict;

class Test::Streamer with POEx::Role::Streaming { }

my ($fh1, $file1) = tempfile();
my ($fh2, $file2) = tempfile();

io($file1)->print(Text::Lorem->new()->paragraphs(10));

my $streamer = Test::Streamer->new(input_handle => $fh1, output_handle => $fh2);
POE::Kernel->run();
is(io($file2)->slurp, io($file1)->slurp, 'data streamed appropriately');
done_testing();
