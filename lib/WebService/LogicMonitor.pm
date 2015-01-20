package WebService::LogicMonitor;

our $VERSION = '0.0';

# ABSTRACT: Interact with LogicMonitor through their web API

use v5.10.1;    # minimum for CentOS 6.5
use Moo;
use autodie;
use Carp;
use Hash::Merge 'merge';
use LWP::UserAgent;
use JSON;
use List::Util 'first';
use List::MoreUtils 'zip';
use Log::Any qw/$log/;
use URI::QueryParam;
use URI;

has lm_password => (is => 'ro', required => 1);
has lm_username => (is => 'ro', required => 1);
has lm_company  => (is => 'ro', required => 1);

has [qw/_lm_base_url _lm_auth_hash _ua/] => (is => 'lazy');

sub _build__lm_base_url {
    my $self = shift;
    return URI->new(sprintf 'https://%s.logicmonitor.com/santaba/rpc',
        $self->lm_company);
}

sub _build__lm_auth_hash {
    my $self = shift;
    return {
        c => $self->lm_company,
        u => $self->lm_username,
        p => $self->lm_password
    };
}

sub _build__ua {
    my $self = shift;
    return LWP::UserAgent->new(
        timeout => 10,
        agent   => __PACKAGE__ . "/$VERSION",
    );
}

sub _get_uri {
    my ($self, $method) = @_;

    my $uri = $self->_lm_base_url->clone;
    $uri->path_segments($uri->path_segments, $method);
    $uri->query_form_hash($self->_lm_auth_hash);
    $log->debug('URI: ' . $uri->path_query);
    return $uri;
}

sub _get_data {
    my ($self, $method, %params) = @_;

    my $uri = $self->_get_uri($method);

    if (%params) {
        foreach my $param (keys %params) {
            $uri->query_param_append($param, $params{$param});
        }
    }

    $log->debug('URI: ' . $uri->path_query);
    my $res = $self->_ua->get($uri);
    croak "Failed!\n" unless $res->is_success;

    my $res_decoded = decode_json $res->decoded_content;

    if ($res_decoded->{status} != 200) {
        croak(
            sprintf 'Failed to fetch data: [%s] %s',
            $res_decoded->{status},
            $res_decoded->{errmsg});
    }

    return $res_decoded->{data};
}

sub _send_data {
    my ($self, $uri) = @_;
    my $res = $self->_ua->get($uri);
    croak "Failed!\n" unless $res->is_success;
    my $res_decoded = decode_json $res->decoded_content;
    return;
}

sub get_escalation_chains {
    my $self = shift;

    return $self->_get_data('getEscalationChains');
}

# TODO name or id
sub get_escalation_chain_by_name {
    my ($self, $name) = @_;

    my $chains = $self->get_escalation_chains;

    my $chain = first { $_->{name} eq $name } @$chains;
    return $chain;
}

=method C<update_escalation_chain(HashRef $chain)>

id and name are the minimum to update a chain, but everything else that is
not sent in the update will be reset to defaults.

=cut

sub update_escalation_chain {
    my ($self, $chain) = @_;

    my $uri = $self->_get_uri('updateEscalatingChain');

    my $params = merge $chain, $self->_lm_auth_hash;

    if ($params->{destination}) {
        $params->{destination} = encode_json $params->{destination};
    }

    $uri->query_form_hash($params);

    $log->debug('URI: ' . $uri->path_query);

    return $self->_send_data($uri);
}

sub get_accounts {
    my $self = shift;

    return $self->_get_data('getAccounts');
}

sub get_account_by_email {
    my ($self, $email) = @_;

    my $accounts = $self->get_accounts;

    my $account = first { $_->{email} =~ /$email/i } @$accounts;

    croak "Failed to find account with email <$email>" unless $account;

    return $account;
}

=method C<get_data>
  host    string  The display name of the host
  dataSourceInstance  string  The Unique name of the DataSource Instance
  period  string  The time period to Download Data from. Valid inputs include nhours, ndays, nweeks, nmonths, or nyears (ex. 2hours)
  dataPoint{0-n}  string  The unique name of the Datapoint
  start, end  long    Epoch Time in seconds
  graphId integer (Optional) The Unique ID of the Datasource Instance Graph
  graph   string  (Optional) The Unique Graph Name
  aggregate   string  (Optional- defaults to null) Take the "AVERAGE", "MAX", "MIN", or "LAST" of your data
  overviewGraph   string  The name of the Overview Graph to get data from
=cut

sub get_data {
    my ($self, %args) = @_;

    croak "'host' is required" unless $args{host};
    croak "'dsi' is required"  unless $args{dsi};

    my $uri = $self->_get_uri('getData');

    # required
    $uri->query_param_append('host',               $args{host});
    $uri->query_param_append('dataSourceInstance', $args{dsi});

    # optional
    $uri->query_param_append('start', $args{start}) if $args{start};
    $uri->query_param_append('end',   $args{end})   if $args{end};
    $uri->query_param_append('aggregate', $args{aggregate})
      if $args{aggregate};

    # XXX period seems to do nothing if start and end are specified
    $uri->query_param_append('period', $args{period}) if $args{period};

    if ($args{datapoint}) {
        croak "'datapoint' must be an arrayref"
          unless ref $args{datapoint} eq 'ARRAY';

        for my $i (0 .. scalar @{$args{datapoint}} - 1) {
            $uri->query_param_append("dataPoint$i", $args{datapoint}->[$i]);
        }
    }

    $log->debug("Fetching uri: $uri");
    my $res = $self->_ua->get($uri);
    croak "Failed!\n" unless $res->is_success;

    my $res_decoded = decode_json $res->decoded_content;

    if ($res_decoded->{status} != 200) {
        croak(
            sprintf 'Failed to fetch data: [%s] %s',
            $res_decoded->{status},
            $res_decoded->{errmsg});
    }

    my $datapoints = $res_decoded->{data}->{dataPoints};

    $log->debug('Got '
          . scalar @{$res_decoded->{data}->{values}->{$args{dsi}}}
          . ' values');
    my $tzoffset = $res_decoded->{data}->{tzoffset};    # don't need this...?

    my $data = [];
    foreach my $dsi_values (@{$res_decoded->{data}->{values}->{$args{dsi}}}) {

        # the dsi_values array provides the values for the datapoints but the first
        # two entries are time info
        my $epoch      = shift @$dsi_values;
        my $timestring = shift @$dsi_values;

        #require DateTime;
        #my $dt = DateTime->from_epoch(epoch => $epoch);

        if (scalar @$datapoints != scalar @$dsi_values) {

            # TODO just ignore this point and carry on?
            croak 'Number of datapoints doesn\'t match number of values';
        }

        my %values = zip @$datapoints, @$dsi_values;
        push @$data,
          {epoch => $epoch, timestr => $timestring, values => \%values};
    }

    return $data;
}

=method C<get_alerts(...)>

Returns an arrayref of alerts or undef if none found.

See L<http://help.logicmonitor.com/developers-guide/manage-alerts/> for
what parameters are available to filter the alerts.

=cut

sub get_alerts {
    my $self = shift;

    my $data = $self->_get_data('getAlerts', @_);

    return $data->{total} == 0
      ? undef
      : $data->{alerts};
}

=method C<get_host(Str displayname)>

Return a host.

=cut

sub get_host {
    my ($self, $displayname) = @_;

    croak "Missing displayname" unless $displayname;

    return $self->_get_data('getHost', displayName => $displayname);

}

=method C<get_hosts(Int hostgroupid)>

Return an array of hosts in the group specified by C<group_id>

In scalar context, will return an arrayref of hosts in the group.

In array context, will return the same arrayref plus a hashref of the group.

=cut

sub get_hosts {
    my ($self, $hostgroupid) = @_;

    croak "Missing hostgroupid" unless $hostgroupid;

    my $data = $self->_get_data('getHosts', hostGroupId => $hostgroupid);

    return wantarray
      ? ($data->{hosts}, $data->{hostgroup})
      : $data->{hosts};
}

=method C<get_all_hosts>

Convenience wrapper around L</get_hosts> which returns all hosts. B<BEWARE> This will
probably take a while.

=cut

sub get_all_hosts {
    return $_[0]->get_hosts(1);
}

1;
