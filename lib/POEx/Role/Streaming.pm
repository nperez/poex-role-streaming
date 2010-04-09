package POEx::Role::Streaming;

#ABSTRACT: Provides behavior for streaming from one filehandle to another

use MooseX::Declare;

=head1 SYNOPSIS
    
    class MyStreamer with POEx::Role::Streaming
    {
        ...
    }

    my $streamer = MyStreamer->new
    (
        input_handle => $some_handle,
        output_handle => $some_other_handle.
    );

    POE::Kernel->run();

=head1 DESCRIPTION

POEx::Role::Streaming provides a common idiom for streaming data from one filehandle to another. It accomplishes this by making good use of sysread and L<POE::Wheel::ReadWrite>. This Role errs on the side of doing as many blocking reads of the L</input_handle> as possible up front (until the high water mark is hit on the Wheel). If this default isn't suitable for the consumer, simply override L</get_data_from_input_handle>. After Streamer has exhausted the source, and flushed the last of the output, it will clean up after itself by closing the wheel, the handles, and sending all of them out of scope. If an exception happens, it will clean up after itself, and let the DIE signal propagate.

=cut

role POEx::Role::Streaming
{
    use POE::Wheel::ReadWrite;
    use POE::Filter::Stream;
    use MooseX::Types::Moose(':all');
    use POEx::Types(':all');
    use aliased 'POEx::Role::Event';
    with 'POEx::Role::SessionInstantiation';

=attribute_public input_handle

    is: ro, isa: FileHandle, required: 1

This is the handle the consumer wants to read

=cut

    has input_handle =>
    (
        is => 'ro',
        isa => FileHandle,
        clearer => 'clear_input_handle',
        required => 1,
    );

=attribute_public output_handle

    is: ro, isa: FileHandle, required: 1

This is the handle to which the consumer wants to write

=cut

    has output_handle =>
    (
        is => 'ro',
        isa => FileHandle,
        clearer => 'clear_output_handle',
        required => 1,
    );

=attribute_protected filter

    is: ro, isa: Filter, lazy_build: 1

This is the default filter used in the output. It defaults to L<POE::Filter::Stream>. Override _build_filter to provide a different Filter if needed

=cut

    has filter =>
    (
        is => 'ro',
        isa => Filter,
        lazy_build => 1,
    );
    
    method _build_filter { POE::Filter::Stream->new(); }

=attribute_public maximum_buffer_threshold

    is: ro, isa: Int, default: 524288

This is used as the HighMark on the Wheel. Provide a smaller value if the consumer needs to do smaller slurps from the L</input_handle>

=cut

    has maximum_buffer_threshold =>
    (
        is => 'ro',
        isa => Int,
        default => 524288
    );

=attribute_public minimum_buffer_threshold

    is: ro, isa: Int, default: 32768

This is used as the LowMark on the Wheel. Provide a larger value if the consumer needs to stave off jitter.

=cut

    has minimum_buffer_threshold =>
    (
        is => 'ro',
        isa => Int,
        default => 32768,
    );

=attribute_private reading_complete

    is: rw, isa: Bool, default: 0

reading_complete is an indicator set during L</get_data_from_input_handle> if EOF is reached. This helps L</handle_output_flushed> figure out if L</read_more_input> should be executed or if it is time to tear everthing down

=cut

    has reading_complete =>
    (
        is => 'rw',
        isa => Bool,
        default => 0,
    );

=attribute_protected wheel

    is: ro, isa: Wheel, lazy_build: 1, handles: qw/ put shutdown_output flush /

wheel stores the constructed wheel for the L</output_handle>. A few handles are provided as sugar. _build_wheel gathers up L</output_handle>, a clone of L</filter>, L</maximum_buffer_threshold> and L</minimum_buffer_threshold> and constructs a POE::Wheel::ReadWrite. Override this method if more customization is required.

=cut

    has wheel =>
    (
        is => 'ro',
        isa => Wheel,
        lazy_build => 1,
        handles => [qw/ put shutdown_output flush /],
    );

    method _build_wheel
    {
        POE::Wheel::ReadWrite->new
        (
            Handle          => $self->output_handle,
            Filter          => $self->filter->clone(),
            ErrorEvent      => 'handle_output_error',
            HighMark        => $self->maximum_buffer_threshold,
            LowMark         => $self->minimum_buffer_threshold,
            LowEvent        => 'read_more_input',
            FlushedEvent    => 'handle_output_flushed',
            # DUMMY EVENT
            HighEvent       => 'this_does_not_exist',
        );
    }

=method_protected after _start

    is Event

_start is advised to spin up the wheel, fill its buffer with initial data, and setup the signal handler for 'DIE' signals (exceptions)

=cut

    after _start is Event
    {
        $self->wheel();
        $self->read_more_input();
        $self->poe->kernel->sig( 'DIE' => 'die_signal');
    }

=method_protected read_more_input

    is Event

read_more_input fills the L</wheel>'s buffer until the HighMark is hit. It does this by looping over L</get_data_from_input_handle> until it returns undef

=cut

    method read_more_input is Event
    {
        1 while not $self->put(($self->get_data_from_input_handle() || return ));
    }

=method_protected handle_output_flushed

    is Event

This event is called when the L</wheel>'s buffer is empty. If L</reading_complete> is set, clean up happens via L</done_writing>. Otherwise more data is slurped via L</read_more_input>

=cut

    method handle_output_flushed is Event
    {
        if($self->reading_complete)
        {
            $self->done_writing();
        }
        else
        {
            $self->read_more_input();
        }
    }


=method_protected get_data_from_input_handle

get_data_from_input_handle is the actual implementation for reading from L</input_handle>. By default, it uses sysread to return a 4k chunk. If EOF is reached, L</reading_complete> is set and L</done_reading> is executed. If

=cut

    method get_data_from_input_handle
    {
        my $read_bytes = sysread($self->input_handle, my $buffer = '', 4096);
        die "Problems reading from the input_handle: $!" unless defined($read_bytes);
        
        if($read_bytes >= 1)
        {
            return $buffer;
        }
        elsif($read_bytes == 0)
        {
            $self->reading_complete(1);
            $self->done_reading();
            return undef;
        }
    }

=method_protected done_writing

done_writing is called when the last of the output is flushed and there is nothing left to read. It clears the L</wheel>, closes the L</output_handle>, and sends them out of scope

=cut

    method done_writing
    {
        $self->shutdown_output();
        $self->clear_wheel();
        $self->output_handle->close();
        $self->clear_output_handle();
    }

=method_protected done_reading

done_reading is called when EOF is reached. It closes the L</input_handle> and sends it out of scope.

=cut
    
    method done_reading
    {
        $self->input_handle->close();
        $self->clear_input_handle();
    }

=method_protected handle_output_error

    (Str $action, Int $code, Str $message, WheelID $id) is Event

handle_output_error is an event the L</wheel> will call when there is some kind of problem writing. By default it simply dies with the passed information

=cut

    method handle_output_error(Str $action, Int $code, Str $message, WheelID $id) is Event
    {
        die "Action '$action' failed with code '$code' and the following message: $message";
    }

=method_protected die_signal

    (Str $signal, HashRef $ex) is Event

die_signal is our exception handler to which POE delivers DIE signals. By default, it calls L</done_reading> and L</done_writing>. Please note that the signal is not handled and will be propogated.

=cut

    method die_signal(Str $signal, HashRef $ex) is Event
    {
        $self->done_reading();
        $self->done_writing();
    }
}

1;
__END__
