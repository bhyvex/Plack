package Plack::Impl::Danga::Socket;
use strict;
use warnings;

use Plack::Util;
use Plack::HTTPParser qw(parse_http_request);

use Danga::Socket;
use Danga::Socket::Callback;
use IO::Handle;
use IO::Socket::INET;
use HTTP::Status;
use Socket qw/IPPROTO_TCP TCP_NODELAY/;

our $HasAIO = eval {
    require IO::AIO; 1;
};

# from Perlbal
# if this is made too big, (say, 128k), then perl does malloc instead
# of using its slab cache.
use constant READ_SIZE => 61449;  # 60k, to fit in a 64k slab

use constant STATE_HEADER   => 0;
use constant STATE_BODY     => 1;
use constant STATE_RESPONSE => 2;

our $handler = [];
$handler->[STATE_HEADER]   = \&_handle_header;
$handler->[STATE_BODY]     = \&_handle_body;
$handler->[STATE_RESPONSE] = \&_handle_response;

sub new {
    my ($class, %args) = @_;

    my $self = bless {}, $class;
    $self->{host} = delete $args{host} || '0.0.0.0';
    $self->{port} = delete $args{port} || 8080;

    $self;
}

sub run {
    my ($self, $app) = @_;

    my $ssock = IO::Socket::INET->new(
        LocalAddr => $self->{host},
        LocalPort => $self->{port},
        Proto     => 'tcp',
        Listen    => SOMAXCONN,
        ReuseAddr => 1,
        Blocking  => 0,
    ) or die $!;
    IO::Handle::blocking($ssock, 0);

    Danga::Socket->AddOtherFds(fileno($ssock) => sub {
        my $csock = $ssock->accept or return;

        IO::Handle::blocking($csock, 0);
        setsockopt($csock, IPPROTO_TCP, TCP_NODELAY, pack('l', 1)) or die $!;

        my $socket = Danga::Socket::Callback->new(
            handle        => $csock,
            context       => {
                state => STATE_HEADER,
                rbuf  => '',
                app   => $app,
            },
            on_read_ready => sub {
                my ($socket) = @_;
                $self->_next($socket);
            },
        );

        my $env = {
            SERVER_PORT         => $self->{port},
            SERVER_NAME         => $self->{host},
            SCRIPT_NAME         => '',
            'psgi.version'      => [ 1, 0 ],
            'psgi.errors'       => *STDERR,
            'psgi.url_scheme'   => 'http',
            'psgi.async'        => 1,
            'psgi.run_once'     => Plack::Util::FALSE,
            'psgi.multithread'  => Plack::Util::FALSE,
            'psgi.multiprocess' => Plack::Util::FALSE,
            REMOTE_ADDR         => $socket->peer_ip_string,
        };
        $socket->{context}{env} = $env;
    });
}

sub run_loop {
    if ($HasAIO) {
        Danga::Socket->AddOtherFds(IO::AIO::poll_fileno() => \&IO::AIO::poll_cb);
    }
    Danga::Socket->EventLoop;
}

sub _next {
    my ($self, $socket) = @_;
    $handler->[ $socket->{context}{state} ]->($self, $socket);
}

sub _handle_header {
    my ($self, $socket) = @_;

    my $bref = $socket->read(READ_SIZE);
    unless (defined $bref) {
        $socket->close;
        return;
    }
    $socket->{context}{rbuf} .= $$bref;

    my $env = $socket->{context}{env};
    my $reqlen = parse_http_request($socket->{context}{rbuf}, $env);
    if ($reqlen >= 0) {
        $socket->{context}{rbuf} = substr $socket->{context}{rbuf}, $reqlen;

        if ($env->{CONTENT_LENGTH} && $env->{REQUEST_METHOD} =~ /^(?:POST|PUT)$/) {
            $socket->{context}{state} = STATE_BODY;
        }
        else {
            $socket->{context}{state} = STATE_RESPONSE;
        }

        $self->_next($socket);
    }
    elsif ($reqlen == -2) {
        return;
    }
    elsif ($reqlen == -1) {
        $self->_start_response($socket)->(400, ['Content-Type' => 'text/plain' ]);
        $socket->write('400 Bad Request');
    }
}

sub _handle_body {
    my ($self, $socket) = @_;

    my $env = $socket->{context}{env};
    my $response_handler = $self->_response_handler($socket);

    my $bref = $socket->read(READ_SIZE);
    unless (defined $bref) {
        $socket->close;
        return;
    }
    $socket->{context}{rbuf} .= $$bref;

    if (length($socket->{context}{rbuf}) >= $env->{CONTENT_LENGTH}) {
        open my $input, '<', \$socket->{context}{rbuf};
        $env->{'psgi.input'} = $input;
        $response_handler->($socket->{context}{app}, $env);
    }
}

sub _handle_response {
    my ($self, $socket) = @_;

    my $env = $socket->{context}{env};
    my $app = $socket->{context}{app};
    my $response_handler = $self->_response_handler($socket);

    open my $input, "<", \"";
    $env->{'psgi.input'} = $input;
    $response_handler->($app, $env);

}

sub _start_response {
    my($self, $socket) = @_;

    return sub {
        my ($status, $headers) = @_;

        my $hdr;
        $hdr .= "HTTP/1.0 $status @{[ HTTP::Status::status_message($status) ]}\015\012";
        while (my ($k, $v) = splice(@$headers, 0, 2)) {
            $hdr .= "$k: $v\015\012";
        }
        $hdr .= "\015\012";

        $socket->write($hdr);

        return unless defined wantarray;
        return Plack::Util::inline_object(
            write => sub { $socket->write($_[0]) },
            close => sub { $socket->close },
        );
    };
}

sub _response_handler {
    my ($self, $socket) = @_;

    my $state_response = $self->_start_response($socket);

    Scalar::Util::weaken($socket);
    return sub {
        my ($app, $env) = @_;
        my $res = Plack::Util::wrap_error { $app->($env, $state_response) } $env;
        return if scalar(@$res) == 0;

        $state_response->($res->[0], $res->[1]);

        my $body = $res->[2];
        my $disconnect_cb = sub {
            if ($socket->write) {
                $socket->close;
            }
            else {
                $socket->watch_write(1);
                $socket->{on_write_ready} = sub {
                    my ($socket) = @_;
                    $socket->write && $socket->close;
                };
            }
        };

        if ($HasAIO && Plack::Util::is_real_fh($body)) {
            my $offset = 0;
            my $length = -s $body;

            my $sendfile; $sendfile = sub {
                IO::AIO::aio_sendfile($socket->{sock}, $body, $offset, $length - $offset, sub {
                    $offset += shift;
                    if ($offset >= $length) {
                        undef $sendfile;
                        $disconnect_cb->();
                    }
                    else {
                        $sendfile->();
                    }
                });
            };
            $sendfile->();
        }
        elsif (ref $body eq 'GLOB') {
            my $read = do { local $/; <$body> };
            $body->close;
            $disconnect_cb->();
        }
        else {
            Plack::Util::foreach( $body, sub { $socket->write($_[0]) } );
            $disconnect_cb->();
        }
    };
}

1;

__END__


