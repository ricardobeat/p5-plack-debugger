package Plack::App::Debugger;

use strict;
use warnings;

use Try::Tiny;
use Scalar::Util qw[ blessed ];

use JSON::XS;
use File::ShareDir;
use File::Spec::Unix ();

use Plack::App::File;

use parent 'Plack::Component';

use constant DEFAULT_BASE_URL => '/debugger';

sub new {
    my $class = shift;
    my %args  = @_ == 1 && ref $_[0] eq 'HASH' ? %{ $_[0] } : @_;

    $args{'base_url'}         ||= DEFAULT_BASE_URL; 
    $args{'static_url'}       ||= '/static';
    $args{'js_init_url'}      ||= '/js/plack-debugger.js';
    $args{'static_asset_dir'} ||= try { File::ShareDir::dist_dir('Plack-Debugger') } || 'share';

    die "You must pass a reference to a 'Plack::Debugger' instance"
        unless blessed $args{'debugger'} 
            && $args{'debugger'}->isa('Plack::Debugger');

    # ... private data 
    $args{'_static_app'} = Plack::App::File->new( root => $args{'static_asset_dir'} )->to_app;
    $args{'_JSON'}       = JSON::XS->new->utf8->pretty;

    $class->SUPER::new( %args );
}

# accessors ...

sub debugger         { (shift)->{'debugger'}         } # a reference to the Plack::Debugger
sub base_url         { (shift)->{'base_url'}         } # the base URL the debugger application will be mounted at
sub static_url       { (shift)->{'static_url'}       } # the URL root from where the debugger can load static resources
sub js_init_url      { (shift)->{'js_init_url'}      } # the JS application initializer URL
sub static_asset_dir { (shift)->{'static_asset_dir'} } # the directory that the static assets are served from (optional)

# create an injector middleware for this debugger application

sub make_injector_middleware {
    my $self      = shift;
    my $middlware = Plack::Util::load_class('Plack::Middleware::Debugger::Injector');
    my $content   = sub {
        my $env = shift;
        sprintf '<script id="plack-debugger-js-init" type="text/javascript" src="%s#%s"></script>' => ( 
            File::Spec::Unix->canonpath(join "" => $self->base_url, $self->static_url, $self->js_init_url), 
            $env->{'plack.debugger.request_uid'} 
        );
    };
    return sub { $middlware->new( content => $content )->wrap( @_ ) }
}

# ...

sub call {
    my $self = shift;
    my $env  = shift;
    my $r    = Plack::Request->new( $env );

    my $static_url = $self->static_url;

    if ( $r->path_info =~ m!^$static_url! ) {
        # clean off the path and 
        # serve the static resources
        $r->env->{'PATH_INFO'} =~ s!^$static_url!!;
        return $self->{'_static_app'}->( $r->env );
    } 
    else {
        # now handle the requests for results ...

        # this only supports GET requests
        return $self->_create_error_response( 405 => 'Method Not Allowed' )
            if $r->method ne 'GET';

        my ($request_uid, $get_subrequests, $get_specific_subrequest) = grep { $_ } split '/' => $r->path_info;

        # we need to have a request-id at a minimum
        return $self->_create_error_response( 400 => 'Bad Request' )
            unless $request_uid;

        # if no subrequests requested, get the base request
        if ( !$get_subrequests ) {
            return $self->_create_JSON_response(
                200 => {
                    data  => $self->debugger->load_request_results( $request_uid ),
                    links => [
                        $self->_create_link( 'self'           => [ $request_uid ] ),
                        $self->_create_link( 'subrequest.all' => [ $request_uid, '/subrequest' ] ),
                    ]
                }
            );
        }
        # if no specific subrequest is requested, get all the subrequests for a specific request
        elsif ( !$get_specific_subrequest ) {
            my $all_subrequests = $self->debugger->load_all_subrequest_results( $request_uid );
            return $self->_create_JSON_response(
                200 => {
                    data  => $all_subrequests,
                    links => [
                        $self->_create_link( 'self'           => [ $request_uid, '/subrequest' ] ),
                        $self->_create_link( 'request.parent' => [ $request_uid ] ),
                        map {
                            $self->_create_link( 'subrequest' => [ $request_uid, '/subrequest', $_->{'request_uid'} ] ),
                        } @$all_subrequests
                    ]
                }
            );
        }
        # if a specific subrequest is requested, return that 
        else {
            return $self->_create_JSON_response(
                200 => {
                    data  => $self->debugger->load_subrequest_results( $request_uid, $get_specific_subrequest ),
                    links => [
                        $self->_create_link( 'self'                => [ $request_uid, '/subrequest', $get_specific_subrequest ] ),
                        $self->_create_link( 'request.parent'      => [ $request_uid ] ),
                        $self->_create_link( 'subrequest.siblings' => [ $request_uid, '/subrequest' ] ),
                    ]
                }
            );
        }
        
    }
}

# ...

sub _create_error_response {
    my ($self, $status, $body) = @_;
    return [ $status, [ 'Content-Type' => 'text/plain', 'Content-Length' => length $body ], [ $body ] ]
}

sub _create_JSON_response {
    my ($self, $status, $data) = @_;
    my $json = $self->{'_JSON'}->encode( $data );
    return [ $status, [ 'Content-Type' => 'application/json', 'Content-Length' => length $json ], [ $json ] ]
}

sub _create_link {
    my ($self, $rel, $parts) = @_;
    return { 
        rel => $rel, 
        url => File::Spec::Unix->canonpath( join '/' => $self->base_url, @$parts )
    }
}


1;

__END__