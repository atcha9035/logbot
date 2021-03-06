package LogBot::Web::Util;
use local::lib;
use v5.10;
use strict;
use warnings;

use Date::Parse qw( str2time );
use DateTime ();
use Digest::xxHash qw( xxhash32 );
use List::Util qw( any );
use LogBot::Database qw( dbh );
use LogBot::Util qw( normalise_channel time_to_ymd ymd_to_time );
use Mojo::Path ();
use Mojo::URL  ();
use Mojo::Util qw( html_unescape xml_escape );
use Readonly;
use URI::Find ();

our @EXPORT_OK = qw(
    nick_hash nick_colour nick_colour_init
    rewrite_old_urls
    url_for_channel irc_host
    channel_from_param date_from_param
    linkify
);
use parent 'Exporter';

sub nick_hash {
    my ($nick) = @_;
    $nick = lc($nick);
    $nick =~ s/[`_]+$//;
    $nick =~ s/\|.*$//;

    return xxhash32($nick, 0);
}

my $nick_colour_cache = {};
Readonly::Scalar my $MAX_NICK_CACHE_COUNT => 1_000;

# don't let the cache grow above a specified size
sub nick_colour_init {
    my $count = scalar keys %{$nick_colour_cache};
    return if $count < $MAX_NICK_CACHE_COUNT;
    my @hashes = sort { $nick_colour_cache->{$a}->[0] <=> $nick_colour_cache->{$b}->[0] } keys %{$nick_colour_cache};
    splice(@hashes, 0, $MAX_NICK_CACHE_COUNT);
    foreach my $hash (@hashes) {
        delete $nick_colour_cache->{$hash};
    }
}

sub nick_colour {
    my ($hash) = @_;

    if (my $cached = $nick_colour_cache->{$hash}) {
        return $cached->[1];
    }
    $hash = $hash + 0;

    my $h = $hash % 360;
    my $l = $h >= 30 && $h <= 210 ? 30 : 50;
    my $s = 20 + $hash % 80;

    my $colour = 'hsl(' . $h . ',' . $s . '%,' . $l . '%)';

    $nick_colour_cache->{$hash} = [time(), $colour];
    return $colour;
}

sub rewrite_old_urls {
    my ($c) = @_;
    my $network_channel = $c->req->query_params->param('c') // return;

    my ($network, $channel);
    if ($network_channel =~ /^([^#]+)(#.+)/) {
        ($network, $channel) = ($1, $2);
    } else {
        ($network, $channel) = ('mozilla', $network_channel);
    }
    $channel = normalise_channel($channel);

    my $path = Mojo::Path->new();
    my $url  = $c->req->url->to_abs();

    # remove network subdomain
    my @host = split(/\./, $url->host);
    if (any { $_ eq 'logs' } @host) {
        shift @host while $host[0] ne 'logs';
        $url->host(join('.', @host));
    }

    # map network to subdomain
    if ($url->host ne 'localhost') {
        $url->host($network . '.' . $url->host);
    }

    # map port
    my $default_url = Mojo::URL->new($c->stash('config')->{url});
    $url->port($default_url->port);

    # find action
    my $req_query = $c->req->query_params;
    my $a         = $req_query->param('a') // 'browse';
    my $q         = $req_query->param('q') // '';

    if ($a eq 'browse') {

        # check for redirects that require a date lookup
        if (my $comment_id = $req_query->param('cid')) {
            if ($comment_id =~ s/^c(\d+)$/$1/) {
                my $dbh = dbh($c->stash('config'), cached => 1);
                my $time = $dbh->selectrow_array('SELECT time FROM logs WHERE channel = ? AND old_id = ? LIMIT 1',
                    undef, $channel, $comment_id);
                if ($time) {
                    $req_query->param('s', time_to_ymd($time));
                }
            }
            $url->fragment($req_query->param('cid'));
            $req_query->param('cid', undef);
        }

        # c=mozilla%23developers&s=8+Jul+2017&e=8+Jul+2017
        # note: multi-date ranges are no longer supported
        push @{$path}, substr($channel, 1);
        if (my $time = str2time($req_query->param('s') // '')) {
            push @{$path}, time_to_ymd($time);
        }

        $url->query('');

    } elsif ($a eq 'search' && $q ne '') {

        # a=search&c=mozilla%23developers&q=glob&ss=8+Jun+2017&se=

        my %query = (q => $q, ch => $channel, ft => 'n');

        if (my $time = str2time($req_query->param('ss') // '')) {
            $query{f} = time_to_ymd($time, '-');
            $query{w} = 'c';
        }
        if (my $time = str2time($req_query->param('se') // '')) {
            $query{t} = time_to_ymd($time, '-');
            $query{w} = 'c';
        }

        $url->query(%query);
    }

    $url->path($path);
    return $url->to_string;
}

sub url_for_channel {
    my %params = @_;
    my @path = substr($params{channel}, 1);
    if ($params{date}) {
        push @path, ref($params{date}) ? $params{date}->ymd('') : $params{date};
    }
    return '/' . join('/', @path);
}

sub irc_host {
    my ($config, %params) = @_;

    my $url = $config->{irc}->{host};

    if ($url =~ s/^ssl:// && $params{url}) {
        $url = 'ircs://' . $url;
        $url =~ s/:6697$//;
    } elsif ($params{url}) {
        $url = ($url =~ /:6697$/ ? 'ircs' : 'irc') . '://' . $url;
        $url =~ s/:6667$//;
    }

    $url =~ s/:\d+$// unless $params{url};
    $url .= '/' if $params{url} || $params{channel};
    $url .= substr($params{channel}, 1) if $params{channel};

    return $url;
}

sub channel_from_param {
    my ($c)     = @_;
    my $config  = $c->stash('config');
    my $channel = normalise_channel($c->param('channel'));

    if (!exists $config->{channels}->{$channel}
        || ($config->{channels}->{$channel}->{disabled} && !$config->{channels}->{$channel}->{web_only}))
    {
        my $message = "The channel $channel is not logged.";
        $c->res->code(404);
        $c->res->message($message);
        LogBot::Web::Index::render($c, { error => $message });
        return undef;
    }

    return $channel;
}

sub date_from_param {
    my ($c) = @_;

    # find date
    my $time = ymd_to_time($c->param('date')) // time();
    my $date = DateTime->from_epoch(epoch => $time)->truncate(to => 'day');

    # difficult to log future events
    return $date > $c->stash('today') ? undef : $date;
}

sub linkify {
    my ($value) = @_;

    # linkify urls
    my $finder = URI::Find->new(
        sub {
            my ($uri, $orig_uri) = @_;
            return '<a href="' . $uri . '" rel="nofollow">' . shorten_url($orig_uri) . '</a>';
        }
    );
    $finder->find(\$value, \&xml_escape);

    # munge email addresses
    $value =~ s{([a-zA-Z0-9\.-]+)\@(([a-zA-Z0-9\.-]+\.)+[a-zA-Z0-9\.-]+)}{$1&odot;$2}g;

    # linkify "bug NNN"
    $value =~ s{(\bbug\s+(\d+))}{<a href="https://bugzilla.mozilla.org/show_bug.cgi?id=$2">$1</a>}gi;

    # linkify "servo: merge #NNN"
    $value =~ s{(\bservo: Merge \#(\d+))}{<a href="https://github.com/servo/servo/pull/$2">$1</a>}gi;

    return $value;
}

# trims the middle of a url, or generates nice short version
sub shorten_url {
    my ($value) = @_;

    # protocol and www is noise
    $value =~ s{^https?://(?:www\.)?}{};
    $value =~ s{/$}{};

    # bmo
    $value =~ s{^bugzilla\.mozilla\.org/show_bug\.cgi\?id=(\d+)}{bugzilla.mozilla.org/$1}
        && return $value;

    # hgmo
    $value =~ s{^hg\.mozilla\.org/(?:(?:integration|releases)/)?([^/]+)/rev/([0-9a-f]+)$}{$1/$2}
        && return $value;
    $value =~ s{^hg\.mozilla\.org/(?:[^/]+/)?([^/]+)/pushloghtml\?startID=(\d+)&endID=(\d+)}{$1 pushlog:$2-$3}
        && return $value;

    # github
    $value =~ s{^github\.com/([^/]+/[^/]+)/(?:issues|pull)/(\d+)}{$1 #$2}
        && return $value;
    $value =~ s{^github\.com/([^/]+/[^/]+)/commit/([a-z0-9]{7})(?:[a-z0-9]{33})?}{$1 $2}
        && return $value;

    # treeherder
    $value =~ s{^treeherder\.mozilla\.org/#/jobs\?repo=([^&]+)&amp;revision=([0-9a-f]+)$}{treeherder $1:$2}
        && return $value;

    # shorten in the middle

    # really this should be the length of $unescaped, but it's not worth the
    # overhead to do so
    return $value if length($value) < 70;

    # trim the middle of the string
    # need to unescape string to avoid splitting enties
    $value = html_unescape($value);
    my $diff = length($value) - 70;
    substr($value, (length($value) / 2) - ($diff / 2), $diff, "\0");
    $value = xml_escape($value);
    $value =~ s/\0/&hellip;/;
    return $value;
}

1;
