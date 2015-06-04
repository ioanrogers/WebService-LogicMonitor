package WebService::LogicMonitor;

our $VERSION = '0.0';

# ABSTRACT: Interact with LogicMonitor through their web API

use v5.16.3;    # minimum for CentOS 7
use autodie;
use Carp;
use DateTime;
use Hash::Merge 'merge';
use LWP::UserAgent;
use JSON;
use List::Util 'first';
use List::MoreUtils 'zip';
use Log::Any qw/$log/;
use URI::QueryParam;
use URI;
use Moo;

=attr C<company>, C<username>, C<password>

The CUP authentication details for your LogicMonitor account. See
L<http://help.logicmonitor.com/developers-guide/authenticating-requests/>

=cut

has [qw/password username company/] => (
    is       => 'ro',
    required => 1,
    isa      => sub { die 'must be defined' unless defined $_[0] },
);

has [qw/_base_url _auth_hash _ua/] => (is => 'lazy');

sub _build__base_url {
    my $self = shift;
    return URI->new(sprintf 'https://%s.logicmonitor.com/santaba/rpc',
        $self->company);
}

sub _build__auth_hash {
    my $self = shift;
    return {
        c => $self->company,
        u => $self->username,
        p => $self->password
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

    my $uri = $self->_base_url->clone;
    $uri->path_segments($uri->path_segments, $method);
    $uri->query_form_hash($self->_auth_hash);
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
    my ($self, $method, $params) = @_;

    my $uri = $self->_get_uri($method);

    $params = merge $params, $self->_auth_hash;
    $uri->query_form_hash($params);

    $log->debug('URI: ' . $uri->path_query);

    my $res = $self->_ua->get($uri);
    croak "Failed!\n" unless $res->is_success;

    my $res_decoded = decode_json $res->decoded_content;

    if ($res_decoded->{status} != 200) {
        croak(
            sprintf 'Failed to send data: [%s] %s',
            $res_decoded->{status},
            $res_decoded->{errmsg});
    }

    return $res_decoded->{data};
}

=method C<get_escalation_chains>

Returns an arrayref of all available escalation chains.

L<http://help.logicmonitor.com/developers-guide/manage-escalation-chains/#get1>

=cut

sub get_escalation_chains {
    my $self = shift;

    my $data = $self->_get_data('getEscalationChains');

    require WebService::LogicMonitor::EscalationChain;

    my @chains;
    foreach my $chain (@$data) {
        $chain->{_lm} = $self;
        push @chains, WebService::LogicMonitor::EscalationChain->new($chain);
    }

    return \@chains;
}

=method C<get_escalation_chain_by_name(Str $name)>

Convenience wrapper aroung L</get_escalation_chains> which only returns chains
where a C<name eq $name>.

=cut

# TODO name or id
sub get_escalation_chain_by_name {
    my ($self, $name) = @_;

    my $chains = $self->get_escalation_chains;

    my $chain = first { $_->{name} eq $name } @$chains;
    return $chain;
}

=method C<get_accounts>

Retrieves a complete list of accounts as an arrayref.

L<http://help.logicmonitor.com/developers-guide/manage-user-accounts/#getAccounts>

=cut

sub get_accounts {
    my $self = shift;

    my $data = $self->_get_data('getAccounts');

    require WebService::LogicMonitor::Account;

    my @accounts;
    for (@$data) {
        $_->{_lm} = $self;
        push @accounts, WebService::LogicMonitor::Account->new($_);
    }

    return \@accounts;
}

=method C<get_account_by_email(Str $email)>

Convenience wrapper aroung L</get_accounts> which only returns accounts
matching $email.

=cut

sub get_account_by_email {
    my ($self, $email) = @_;

    my $accounts = $self->get_accounts;

    $log->debug("Searching for a user account with email address [$email]");

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

# TODO why does this work with only host display name and not id?
sub get_data {
    my ($self, %args) = @_;

    # required params
    croak "'host' is required" unless $args{host};
    my %params = (host => $args{host},);

    if ($args{datasource_instance}) {
        $params{dataSourceInstance} = $args{datasource_instance};
    } elsif ($args{datasource}) {
        $params{dataSource} = $args{datasource};
    } else {
        croak "Either 'datasource' or 'datasource_instance' must be specified";
    }

    # optional params
    for (qw/start end aggregate period/) {
        $params{$_} = $args{$_} if $args{$_};
    }

    if ($args{datapoint}) {
        croak "'datapoint' must be an arrayref"
          unless ref $args{datapoint} eq 'ARRAY';

        for my $i (0 .. scalar @{$args{datapoint}} - 1) {
            $params{"dataPoint$i"} = $args{datapoint}->[$i];
        }
    }

    my $data = $self->_get_data('getData', %params);

    require WebService::LogicMonitor::DataSourceData;
    return WebService::LogicMonitor::DataSourceData->new($data);
}

=method C<get_alerts(...)>

Returns an arrayref of alerts or undef if none found.

See L<http://help.logicmonitor.com/developers-guide/manage-alerts/> for
what parameters are available to filter the alerts.

=cut

sub get_alerts {
    my ($self, %args) = @_;

    my %transform = (
        ack_filter => 'ackFilter',
        filter_sdt => 'filterSDT',
    );

    for my $key (keys %transform) {
        $args{$transform{$key}} = delete $args{$key}
          if exists $args{$key};
    }

    my $data = $self->_get_data('getAlerts', %args);

    return if $data->{total} == 0;

    require WebService::LogicMonitor::Alert;

    my @alerts = map {
        $_->{_lm} = $self;
        WebService::LogicMonitor::Alert->new($_);
    } @{$data->{alerts}};

    return \@alerts;

}

=method C<get_host(Str displayname)>

Return a host.

L<http://help.logicmonitor.com/developers-guide/manage-hosts/#get1>

=cut

sub get_host {
    my ($self, $displayname) = @_;

    croak "Missing displayname" unless $displayname;

    my $data = $self->_get_data('getHost', displayName => $displayname);

    require WebService::LogicMonitor::Host;
    $data->{_lm} = $self;
    return WebService::LogicMonitor::Host->new($data);
}

=method C<get_hosts(Int hostgroupid)>

Return an array of hosts in the group specified by C<group_id>

L<http://help.logicmonitor.com/developers-guide/manage-hosts/#get1>

In scalar context, will return an arrayref of hosts in the group.

In array context, will return the same arrayref plus a hashref of the group.

=cut

sub get_hosts {
    my ($self, $hostgroupid) = @_;

    croak "Missing hostgroupid" unless $hostgroupid;

    my $data = $self->_get_data('getHosts', hostGroupId => $hostgroupid);

    require WebService::LogicMonitor::Host;

    my @hosts;
    for (@{$data->{hosts}}) {
        $_->{_lm} = $self;
        push @hosts, WebService::LogicMonitor::Host->new($_);
    }

    return wantarray
      ? (\@hosts, $data->{hostgroup})
      : \@hosts;
}

=method C<get_all_hosts>

Convenience wrapper around L</get_hosts> which returns all hosts. B<BEWARE> This will
probably take a while.

=cut

sub get_all_hosts {
    return $_[0]->get_hosts(1);
}

=method C<get_host_groups(Str|Regexp filter?)>

Returns an arrayref of all host groups.

L<http://help.logicmonitor.com/developers-guide/manage-host-group/#list>

Optionally takes a string or regexp as an argument. Only those hostgroups with names
matching the argument will be returned, or undef if there are none. If the arg is a string,
it must be an exact match with C<eq>.

=cut

sub get_groups {
    my ($self, $key, $value) = @_;

    $log->debug('Fetching a list of groups');

    my $data = $self->_get_data('getHostGroups');

    $log->debug('Number of hosts found: ' . scalar @$data);

    return unless scalar @$data > 0;

    if (defined $key && !defined $value) {
        die "Cannot search on $key without a value";
    }

    require WebService::LogicMonitor::Group;

    if (!defined $value) {
        my @groups = map {
            $_->{_lm} = $self;
            WebService::LogicMonitor::Group->new($_);
        } @$data;
        return \@groups;
    }

    my $filter_is_regexp;
    $log->debug("Filtering hosts on [$key] with [$value]");
    if (ref $value && ref $value eq 'Regexp') {
        $log->debug('Filter is a regexp');
        $filter_is_regexp = 1;
    } else {
        $log->debug('Filter is a string');
    }

    my @groups = map {
        die "This key is not valid: $key" unless $_->{$key};
        if ($filter_is_regexp ? $_->{$key} =~ $value : $_->{$key} eq $value) {
            $_->{_lm} = $self;
            WebService::LogicMonitor::Group->new($_);
        } else {
            ();
        }
    } @$data;

    $log->debug('Number of hosts after filter: ' . scalar @groups);

    return @groups ? \@groups : undef;
}

=method C<get_sdts(Str key?, Int id?)>

Returns an array of SDT hashes. With no args, it will return all SDTs in the
account. See the LoMo docs for details on what keys are supported.

L<http://help.logicmonitor.com/developers-guide/schedule-down-time/get-sdt-data/>

=cut

sub get_sdts {
    my ($self, $key, $id) = @_;

    my $data;
    if ($key) {
        defined $id or croak 'Can not specify a key without an id';
        $data = $self->_get_data('getSDTs', $key => $id);
    } else {
        $data = $self->_get_data('getSDTs');
    }

    require WebService::LogicMonitor::SDT;

    my @sdts;
    for (@$data) {
        $_->{_lm} = $self;
        push @sdts, WebService::LogicMonitor::SDT->new($_);
    }

    return \@sdts;
}

=method C<set_sdt(Str entity, Int|Str id, start => DateTime|Str, end => DateTime|Str, comment => Str?)>

Sets SDT for an entity. Entity can be

  Host
  HostGroup
  HostDataSource
  DataSourceInstance
  HostDataSourceInstanceGroup
  Agent

The id for Host can be either an id number or hostname string.

To simplify calling this we take two keys, C<start> and C<end> which must
be either L<DateTime> objects or ISO8601 strings parseable by
L<DateTime::Format::ISO8601>.

L<http://help.logicmonitor.com/developers-guide/schedule-down-time/set-sdt-data/>

  $lomo->set_sdt(
      Host    => 'somehost',
      start   => '20151101T1000',
      end     => '20151101T1350',
      comment => 'Important maintenance',
  );

=cut

sub set_sdt {
    my ($self, $entity, $id, %args) = @_;

    # generate the method name and id key from entity
    my $method = 'set' . $entity . 'SDT';
    my $id_key;

    if ($id =~ /^\d+$/) {
        $id_key = lcfirst $entity . 'Id';
    } elsif ($entity eq 'Host') {
        $id_key = 'host';
    } else {
        croak "Invalid parameters - $entity => $id";
    }

    if (exists $args{type} && $args{type} != 1) {
        croak 'We only handle one-time SDTs right now';
    }

    $args{type} = 1;

    my $params = {
        $id_key => $id,
        type    => $args{type},
    };

    $params->{comment} = $args{comment} if exists $args{comment};

    croak 'Missing start time' unless $args{start};
    croak 'Missing end time'   unless $args{end};

    require DateTime::Format::ISO8601;

    my ($start_dt, $end_dt);
    if (!ref $args{start}) {
        $start_dt = DateTime::Format::ISO8601->parse_datetime($args{start});
    } else {
        $start_dt = $args{start};
    }

    if (!ref $args{end}) {
        $end_dt = DateTime::Format::ISO8601->parse_datetime($args{end});
    } else {
        $end_dt = $args{end};
    }

    # LoMo expects months to be 0..11
    @$params{(qw/year month day hour minute/)} = (
        $start_dt->year, ($start_dt->month - 1),
        $start_dt->day, $start_dt->hour, $start_dt->minute
    );

    @$params{(qw/endYear endMonth endDay endHour endMinute/)} = (
        $end_dt->year, ($end_dt->month - 1),
        $end_dt->day, $end_dt->hour, $end_dt->minute
    );

    my $res = $self->_send_data($method, $params);

    require WebService::LogicMonitor::SDT;
    $res->{_lm} = $self;
    return WebService::LogicMonitor::SDT->new($res);
}

=method C<set_quick_sdt(Str entity, Int|Str id, $hours, ...)>

Wrapper around L</set_sdt> to quickly set SDT starting immediately. The lenght
of the SDT can be specfied as hours, minutes or any other unit supported by
L<https://metacpan.org/pod/DateTime#Adding-a-Duration-to-a-Datetime>, but only
one unit can be specified.

  $lomo->set_quick_sdt(Host => 'somehost', minutes => 30, comment => 'Reboot to annoy support');
  $lomo->set_quick_sdt(HostGroup => 456, hours => 6);

=cut

sub set_quick_sdt {
    my $self   = shift;
    my $entity = shift;
    my $id     = shift;
    my $units  = shift;
    my $value  = shift;

    my $start_dt = DateTime->now(time_zone => 'UTC');
    my $end_dt = $start_dt->clone->add($units => $value);

    return $self->set_sdt(
        $entity => $id,
        start   => $start_dt,
        end     => $end_dt,
        @_
    );
}

1;

__END__

=head1 SYNOPSIS

  use v5.14.1;
  use strict;
  use Try::Tiny;
  use WebService::LogicMonitor;

  # find a hostgroup by name, iterate through its child groups
  # and check the status of a datasource instance

  my $lm = WebService::LogicMonitor->new(
      username => $ENV{LOGICMONITOR_USER},
      password => $ENV{LOGICMONITOR_PASS},
      company  => $ENV{LOGICMONITOR_COMPANY},
  );

  my $datasource = 'Ping';
  my $host_groups  = try {
      my $hg = $lm->get_host_groups(name => 'Abingdon');
      die 'No such host group' unless $hg;
      $lm->get_host_group_children($hg->[0]{id});
  } catch {
      die "Error retrieving host group: $_";
  };

  die 'Host group has no children' unless $host_groups;

  foreach my $hg (@$host_groups) {
      say "Checking group: $hg->{name}";
      my $hosts = $lm->get_hosts($hg->{id});

      foreach my $host (@$hosts) {
          say "\tChecking host: $host->{hostName}";
          my $instances = try {
              $lm->get_data_source_instances($host->{id}, $datasource);
          }
          catch {
              say "Failed to retrieve data source instances: " . $_;
              return undef;
          };

          next unless $instances;

          # only one instance
          my $instance = shift @$instances;

          say "\t\tdatasource status: " . ($instance->{enabled} ? 'enabled' : 'disabled');
          say "\t\talert status: " . ($instance->{alertEnable} ? 'enabled' : 'disabled');
      }
  }
