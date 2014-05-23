# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id$

# Sympa - SYsteme de Multi-Postage Automatique
#
# Copyright (c) 1997, 1998, 1999 Institut Pasteur & Christophe Wolfhugel
# Copyright (c) 1997, 1998, 1999, 2000, 2001, 2002, 2003, 2004, 2005,
# 2006, 2007, 2008, 2009, 2010, 2011 Comite Reseau des Universites
# Copyright (c) 2011, 2012, 2013, 2014 GIP RENATER
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Bulk;

use strict;
use warnings;
use Encode;
use Mail::Address;
use Time::HiRes qw(time);
use MIME::Parser;
use MIME::Base64;
use Term::ProgressBar;
use URI::Escape;
use constant MAX => 100_000;

use tools;
use tt2;
use Sympa::Language;
use Log;
use Conf;
use List;
use SDM;

## Database and SQL statement handlers
my $sth;

# fingerprint of last message stored in bulkspool
my $message_fingerprint;

# create an empty Bulk
#sub new {
#    my $pkg = shift;
#    my $packet = Bulk::next();;
#    bless \$packet, $pkg;
#    return $packet
#}
##
# get next packet to process, order is controled by priority_message, then by
# priority_packet, then by creation date.
# Packets marked as being sent with VERP will be treated last.
# Next lock the packetb to prevent multiple proccessing of a single packet

sub next {
    Log::do_log('debug', 'Bulk::next');

    # lock next packet
    my $lock = tools::get_lockname();

    my $order;
    my $limit_oracle = '';
    my $limit_sybase = '';
    my $limit_other  = '';
    ## Only the first record found is locked, thanks to the "LIMIT 1" clause
    $order =
        'ORDER BY priority_message_bulkmailer ASC, priority_packet_bulkmailer ASC, reception_date_bulkmailer ASC, verp_bulkmailer ASC';
    if (   $Conf::Conf{'db_type'} eq 'mysql'
        or $Conf::Conf{'db_type'} eq 'Pg'
        or $Conf::Conf{'db_type'} eq 'SQLite') {
        $limit_other = 'LIMIT 1';
    } elsif ($Conf::Conf{'db_type'} eq 'Oracle') {
        $limit_oracle = 'AND rownum <= 1';
    } elsif ($Conf::Conf{'db_type'} eq 'Sybase') {
        $limit_sybase = 'TOP 1';
    }

    # Select the most prioritary packet to lock.
    unless (
        $sth = SDM::do_prepared_query(
            sprintf(
                q{SELECT %s messagekey_bulkmailer AS messagekey,
		         packetid_bulkmailer AS packetid
		  FROM bulkmailer_table
		  WHERE lock_bulkmailer IS NULL AND
		        delivery_date_bulkmailer <= ?
		  %s %s %s},
                $limit_sybase, $limit_oracle, $order, $limit_other
            ),
            int time
        )
        ) {
        Log::do_log('err',
            'Unable to get the most prioritary packet from database');
        return undef;
    }

    my $packet;
    unless ($packet = $sth->fetchrow_hashref('NAME_lc')) {
        return undef;
    }

    my $sth;
    # Lock the packet previously selected.
    unless (
        $sth = SDM::do_query(
            "UPDATE bulkmailer_table SET lock_bulkmailer=%s WHERE messagekey_bulkmailer='%s' AND packetid_bulkmailer='%s' AND lock_bulkmailer IS NULL",
            SDM::quote($lock),
            $packet->{'messagekey'},
            $packet->{'packetid'}
        )
        ) {
        Log::do_log('err', 'Unable to lock packet %s for message %s',
            $packet->{'packetid'}, $packet->{'messagekey'});
        return undef;
    }

    if ($sth->rows < 0) {
        Log::do_log(
            'err',
            'Unable to lock packet %s for message %s, though the query succeeded',
            $packet->{'packetid'},
            $packet->{'messagekey'}
        );
        return undef;
    }
    unless ($sth->rows) {
        Log::do_log('info', 'Bulk packet is already locked');
        return undef;
    }

    # select the packet that has been locked previously
    #FIXME: A column name is recEipients_bulkmailer.
    unless (
        $sth = SDM::do_query(
            "SELECT messagekey_bulkmailer AS messagekey, messageid_bulkmailer AS messageid, packetid_bulkmailer AS packetid, receipients_bulkmailer AS recipients, returnpath_bulkmailer AS returnpath, listname_bulkmailer AS listname, robot_bulkmailer AS robot, priority_message_bulkmailer AS priority_message, priority_packet_bulkmailer AS priority_packet, verp_bulkmailer AS verp, tracking_bulkmailer AS tracking, merge_bulkmailer as merge, reception_date_bulkmailer AS reception_date, delivery_date_bulkmailer AS delivery_date FROM bulkmailer_table WHERE lock_bulkmailer=%s %s",
            SDM::quote($lock),
            $order
        )
        ) {
        Log::do_log('err',
            'Unable to retrieve informations for packet %s of message %s',
            $packet->{'packetid'}, $packet->{'messagekey'});
        return undef;
    }

    my $result = $sth->fetchrow_hashref('NAME_lc');

    return $result;

}

# remove a packet from database by packet id. return undef if packet does not
# exist

sub remove {
    my $messagekey = shift;
    my $packetid   = shift;

    Log::do_log('debug', "Bulk::remove(%s,%s)", $messagekey, $packetid);

    unless (
        $sth = SDM::do_query(
            "DELETE FROM bulkmailer_table WHERE packetid_bulkmailer = %s AND messagekey_bulkmailer = %s",
            SDM::quote($packetid),
            SDM::quote($messagekey)
        )
        ) {
        Log::do_log('err', 'Unable to delete packet %s of message %s',
            $packetid, $messagekey);
        return undef;
    }
    return $sth;
}

sub messageasstring {
    my $messagekey = shift;
    Log::do_log('debug', 'Bulk::messageasstring(%s)', $messagekey);

    unless (
        $sth = SDM::do_query(
            "SELECT message_bulkspool AS message FROM bulkspool_table WHERE messagekey_bulkspool = %s",
            SDM::quote($messagekey)
        )
        ) {
        Log::do_log(
            'err',
            'Unable to retrieve message %s text representation from database',
            $messagekey
        );
        return undef;
    }

    my $messageasstring = $sth->fetchrow_hashref('NAME_lc');

    unless ($messageasstring) {
        Log::do_log('err', "could not fetch message $messagekey from spool");
        return undef;
    }
    my $msg = MIME::Base64::decode($messageasstring->{'message'});
    unless ($msg) {
        Log::do_log('err',
            "could not decode message $messagekey extrated from spool (base64)"
        );
        return undef;
    }
    return $msg;
}
#################################"
# fetch message from bulkspool_table by key
#
sub message_from_spool {
    my $messagekey = shift;
    Log::do_log('debug', '(messagekey : %s)', $messagekey);

    unless (
        $sth = SDM::do_query(
            "SELECT message_bulkspool AS message, messageid_bulkspool AS messageid, dkim_d_bulkspool AS  dkim_d,  dkim_i_bulkspool AS  dkim_i, dkim_privatekey_bulkspool AS dkim_privatekey, dkim_selector_bulkspool AS dkim_selector FROM bulkspool_table WHERE messagekey_bulkspool = %s",
            SDM::quote($messagekey)
        )
        ) {
        Log::do_log('err',
            'Unable to retrieve message %s full data from database',
            $messagekey);
        return undef;
    }

    my $message_from_spool = $sth->fetchrow_hashref('NAME_lc');
    $sth->finish;

    return (
        {   'messageasstring' =>
                MIME::Base64::decode($message_from_spool->{'message'}),
            'messageid'       => $message_from_spool->{'messageid'},
            'dkim_d'          => $message_from_spool->{'dkim_d'},
            'dkim_i'          => $message_from_spool->{'dkim_i'},
            'dkim_selector'   => $message_from_spool->{'dkim_selector'},
            'dkim_privatekey' => $message_from_spool->{'dkim_privatekey'},
        }
    );

}

############################################################
#  merge_msg                                               #
############################################################
#  Merge a message with custom attributes of a user.       #
#                                                          #
#                                                          #
#  IN : - MIME::Entity                                     #
#       - $rcpt : a recipient                              #
#       - $bulk : HASH                                     #
#       - $data : HASH with user's data                    #
#  OUT : 1 | undef                                         #
#                                                          #
############################################################
sub merge_msg {
    my $entity = shift;
    my $rcpt   = shift;
    my $bulk   = shift;
    my $data   = shift;

    unless (ref $entity eq 'MIME::Entity') {
        Log::do_log('err', 'false entity');
        return undef;
    }

    # Initialize parameters at first only once.
    $data->{'headers'} ||= {};
    my $headers = $entity->head;
    foreach my $key (
        qw/subject x-originating-ip message-id date x-original-to from to thread-topic content-type/
        ) {
        next unless $headers->count($key);
        my $value = $headers->get($key, 0);
        chomp $value;
        $value =~ s/(?:\r\n|\r|\n)(?=[ \t])//g;    # unfold
        $data->{'headers'}{$key} = $value;
    }
    $data->{'subject'} = tools::decode_header($headers, 'Subject');

    return _merge_msg($entity, $rcpt, $bulk, $data);
}

sub _merge_msg {
    my $entity = shift;
    my $rcpt   = shift;
    my $bulk   = shift;
    my $data   = shift;

    my $enc = $entity->head->mime_encoding;
    # Parts with nonstandard encodings aren't modified.
    if ($enc and $enc !~ /^(?:base64|quoted-printable|[78]bit|binary)$/i) {
        return $entity;
    }
    my $eff_type = $entity->effective_type || 'text/plain';
    # Signed or encrypted parts aren't modified.
    if ($eff_type =~ m{^multipart/(signed|encrypted)$}) {
        return $entity;
    }

    if ($entity->parts) {
        foreach my $part ($entity->parts) {
            unless (_merge_msg($part, $rcpt, $bulk, $data)) {
                Log::do_log('err', 'Failed to merge message part');
                return undef;
            }
        }
    } elsif ($eff_type =~ m{^(?:multipart|message)(?:/|\Z)}i) {
        # multipart or message types without subparts.
        return $entity;
    } elsif (MIME::Tools::textual_type($eff_type)) {
        my ($charset, $in_cset, $bodyh, $body, $utf8_body);

        $data->{'part'} = {
            description =>
                tools::decode_header($entity, 'Content-Description'),
            disposition =>
                lc($entity->head->mime_attr('Content-Disposition') || ''),
            encoding => $enc,
            type     => $eff_type,
        };

        $bodyh = $entity->bodyhandle;
        # Encoded body or null body won't be modified.
        if (!$bodyh or $bodyh->is_encoded) {
            return $entity;
        }

        $body = $bodyh->as_string;
        unless (defined $body and length $body) {
            return $entity;
        }

        ## Detect charset.  If charset is unknown, detect 7-bit charset.
        $charset = $entity->head->mime_attr('Content-Type.Charset');
        $in_cset = MIME::Charset->new($charset || 'NONE');
        unless ($in_cset->decoder) {
            $in_cset =
                MIME::Charset->new(MIME::Charset::detect_7bit_charset($body)
                    || 'NONE');
        }
        unless ($in_cset->decoder) {
            Log::do_log('err', 'Unknown charset "%s"', $charset);
            return undef;
        }
        $in_cset->encoder($in_cset);    # no charset conversion

        ## Only decodable bodies are allowed.
        eval { $utf8_body = Encode::encode_utf8($in_cset->decode($body, 1)); };
        if ($@) {
            Log::do_log('err', 'Cannot decode by charset "%s"', $charset);
            return undef;
        }

        ## PARSAGE ##

        my $message_output;
        unless (
            merge_data(
                'rcpt'           => $rcpt,
                'messageid'      => $bulk->{'messageid'},
                'listname'       => $bulk->{'listname'},
                'robot'          => $bulk->{'robot'},
                'data'           => $data,
                'body'           => $utf8_body,
                'message_output' => \$message_output,
            )
            ) {
            Log::do_log('err', 'error merging message');
            return undef;
        }
        $utf8_body = $message_output;

        ## Data not encodable by original charset will fallback to UTF-8.
        my ($newcharset, $newenc);
        ($body, $newcharset, $newenc) =
            $in_cset->body_encode(Encode::decode_utf8($utf8_body),
            Replacement => 'FALLBACK');
        unless ($newcharset) {    # bug in MIME::Charset?
            Log::do_log('err', 'Can\'t determine output charset');
            return undef;
        } elsif ($newcharset ne $in_cset->as_string) {
            $entity->head->mime_attr('Content-Transfer-Encoding' => $newenc);
            $entity->head->mime_attr('Content-Type.Charset' => $newcharset);

            ## normalize newline to CRLF if transfer-encoding is BASE64.
            $body =~ s/\r\n|\r|\n/\r\n/g
                if $newenc and $newenc eq 'BASE64';
        } else {
            ## normalize newline to CRLF if transfer-encoding is BASE64.
            $body =~ s/\r\n|\r|\n/\r\n/g
                if $enc and uc $enc eq 'BASE64';
        }

        ## Save new body.
        my $io = $bodyh->open('w');
        unless ($io
            and $io->print($body)
            and $io->close) {
            Log::do_log('err', 'Can\'t write in Entity: %s', $!);
            return undef;
        }
        $entity->sync_headers(Length => 'COMPUTE')
            if $entity->head->get('Content-Length');

        return $entity;
    }

    return $entity;
}

############################################################
#  merge_data                                              #
############################################################
#  This function retrieves the customized data of the      #
#  users then parse the message. It returns the message    #
#  personalized to bulk.pl                                 #
#  It uses the method tt2::parse_tt2()                      #
#  It uses the method List::get_list_member_no_object()     #
#  It uses the method tools::get_fingerprint()              #
#                                                          #
# IN : - rcpt : the recipient email                        #
#      - listname : the name of the list                   #
#      - robot_id : the host                               #
#      - data : HASH with many data                        #
#      - body : message with the TT2                       #
#      - message_output : object, IO::Scalar               #
#                                                          #
# OUT : - message_output : customized message              #
#     | undef                                              #
#                                                          #
############################################################
sub merge_data {
    my %params             = @_;
    my $rcpt               = $params{'rcpt'},
        my $listname       = $params{'listname'},
        my $robot_id       = $params{'robot'},
        my $data           = $params{'data'},
        my $body           = $params{'body'},
        my $message_output = $params{'message_output'},

        my $options;
    $options->{'is_not_template'} = 1;

    # get_list_member_no_object() return the user's details with the custom
    # attributes
    my $user = List::get_list_member_no_object(
        {   'email'  => $rcpt,
            'name'   => $listname,
            'domain' => $robot_id,
        }
    );

    $user->{'escaped_email'} = URI::Escape::uri_escape($rcpt);
    my $language = Sympa::Language->instance;
    $user->{'friendly_date'} = $language->gettext_strftime("%d %b %Y  %H:%M",
        localtime($user->{'date'}));

    # this method as been removed because some users may forward
    # authentication link
    # $user->{'fingerprint'} = tools::get_fingerprint($rcpt);

    $data->{'user'}     = $user;
    $data->{'robot'}    = $robot_id;
    $data->{'listname'} = $listname;

    # Parse the TT2 in the message : replace the tags and the parameters by
    # the corresponding values
    unless (tt2::parse_tt2($data, \$body, $message_output, '', $options)) {
        Log::do_log('err', 'Unable to parse body : "%s"', \$body);
        return undef;
    }

    return 1;
}

##
sub store {
    my %data = @_;

    my $message = $data{'message'};
    my $msg_id  = $message->{'msg'}->head->get('Message-ID');
    chomp $msg_id;
    my $rcpts            = $data{'rcpts'};
    my $from             = $data{'from'};
    my $robot            = $data{'robot'};
    my $listname         = $data{'listname'};
    my $priority_message = $data{'priority_message'};
    my $priority_packet  = $data{'priority_packet'};
    my $delivery_date    = $data{'delivery_date'};
    my $verp             = $data{'verp'};
    my $tracking         = $data{'tracking'};
    $tracking = '' unless (($tracking eq 'dsn') || ($tracking eq 'mdn'));
    $verp = 0 unless ($verp);
    my $merge = $data{'merge'};
    $merge = 0 unless ($merge);
    my $dkim        = $data{'dkim'};
    my $tag_as_last = $data{'tag_as_last'};

    Log::do_log(
        'debug',
        'Bulk::store(<msg>,<rcpts>,from = %s,robot = %s,listname= %s,priority_message = %s, delivery_date= %s,verp = %s, tracking = %s, merge = %s, dkim: d= %s i=%s, last: %s)',
        $from,
        $robot,
        $listname,
        $priority_message,
        $delivery_date,
        $verp,
        $tracking,
        $merge,
        $dkim->{'d'},
        $dkim->{'i'},
        $tag_as_last
    );

    $priority_message = Conf::get_robot_conf($robot, 'sympa_priority')
        unless ($priority_message);
    $priority_packet = Conf::get_robot_conf($robot, 'sympa_packet_priority')
        unless ($priority_packet);

    #creation of a MIME entity to extract the real sender of a message
    my $parser = MIME::Parser->new();
    $parser->output_to_core(1);

    my $msg = $message->{'msg'}->as_string;
    if ($message->{'protected'}) {
        $msg = $message->{'msg_as_string'};
    }
    my @sender_hdr =
        Mail::Address->parse($message->{'msg'}->head->get('From'));
    my $message_sender = $sender_hdr[0]->address;

    $msg = MIME::Base64::encode($msg);

    ##-----------------------------##

    my $messagekey = tools::md5_fingerprint($msg);

    # first store the message in bulk_spool_table
    # because as soon as packet are created bulk.pl may distribute them
    # Compare the current message finger print to the fingerprint
    # of the last call to store() ($message_fingerprint is a global var)
    # If fingerprint is the same, then the message should not be stored
    # again in bulkspool_table

    my $message_already_on_spool;

    if ($messagekey eq $message_fingerprint) {
        $message_already_on_spool = 1;

    } else {

        ## search if this message is already in spool database : mailfile may
        ## perform multiple submission of exactly the same message
        unless (
            $sth = SDM::do_query(
                "SELECT count(*) FROM bulkspool_table WHERE ( messagekey_bulkspool = %s )",
                SDM::quote($messagekey)
            )
            ) {
            Log::do_log('err',
                'Unable to check whether message %s is in spool already',
                $messagekey);
            return undef;
        }

        $message_already_on_spool = $sth->fetchrow;
        $sth->finish();

        # if message is not found in bulkspool_table store it
        if ($message_already_on_spool == 0) {
            my $statement = q{INSERT INTO bulkspool_table
		  (messagekey_bulkspool, messageid_bulkspool,
		   message_bulkspool, lock_bulkspool,
		   dkim_d_bulkspool, dkim_i_bulkspool,
		   dkim_selector_bulkspool, dkim_privatekey_bulkspool)
		  VALUES (?, ?, ?, 1, ?, ?, ?, ?)};
            my $statementtrace = $statement;
            $statementtrace =~ s/\n\s*/ /g;
            $statementtrace =~ s/\?/\%s/g;

            unless (
                SDM::do_prepared_query(
                    $statement,        $messagekey,
                    $msg_id,           $msg,
                    $dkim->{d},        $dkim->{i},
                    $dkim->{selector}, $dkim->{private_key}
                )
                ) {
                Log::do_log(
                    'err',
                    'Unable to add message in bulkspool_table "%s"',
                    sprintf($statementtrace,
                        SDM::quote($messagekey),
                        SDM::quote($msg_id),
                        SDM::quote(substr($msg, 0, 100)),
                        SDM::quote($dkim->{d}),
                        SDM::quote($dkim->{i}),
                        SDM::quote($dkim->{selector}),
                        SDM::quote(substr($dkim->{private_key}, 0, 30)))
                );
                return undef;
            }

            #log in stat_table to make statistics...
            unless ($message_sender =~ /($robot)\@/) {
                # ignore messages sent by robot
                unless ($message_sender =~ /($listname)-request/) {
                    # ignore messages of requests
                    Log::db_stat_log(
                        {   'robot'     => $robot,
                            'list'      => $listname,
                            'operation' => 'send_mail',
                            'parameter' => length($msg),
                            'mail'      => $message_sender,
                            'client'    => '',
                            'daemon'    => 'sympa.pl'
                        }
                    );
                }
            }
            $message_fingerprint = $messagekey;
        }
    }

    my $current_date = int(time);

    # second : create each recipient packet in bulkmailer_table
    my $type = ref $rcpts;

    unless (ref $rcpts) {
        my @tab = ($rcpts);
        my @tabtab;
        push @tabtab, \@tab;
        $rcpts = \@tabtab;
    }

    my $priority_for_packet;
    my $already_tagged = 0;
    # Initialize counter used to check wether we are copying the last packet.
    my $packet_rank = 0;
    foreach my $packet (@{$rcpts}) {
        $priority_for_packet = $priority_packet;
        if ($tag_as_last && !$already_tagged) {
            $priority_for_packet = $priority_packet + 5;
            $already_tagged      = 1;
        }
        $type = ref $packet;
        my $rcptasstring;
        if (ref $packet eq 'ARRAY') {
            $rcptasstring = join ',', @{$packet};
        } else {
            $rcptasstring = $packet;
        }
        my $packetid = tools::md5_fingerprint($rcptasstring);
        my $packet_already_exist;
        if (ref($listname) =~ /List/i) {
            $listname = $listname->{'name'};
        }
        if ($message_already_on_spool) {
            ## search if this packet is already in spool database : mailfile
            ## may perform multiple submission of exactly the same message
            unless (
                $sth = SDM::do_query(
                    "SELECT count(*) FROM bulkmailer_table WHERE ( messagekey_bulkmailer = %s AND  packetid_bulkmailer = %s)",
                    SDM::quote($messagekey),
                    SDM::quote($packetid)
                )
                ) {
                Log::do_log(
                    'err',
                    'Unable to check presence of packet %s of message %s in database',
                    $packetid,
                    $messagekey
                );
                return undef;
            }
            $packet_already_exist = $sth->fetchrow;
            $sth->finish();
        }

        if ($packet_already_exist) {
            Log::do_log('err',
                'Duplicate message not stored in bulmailer_table');

        } else {
            unless (
                SDM::do_query(
                    "INSERT INTO bulkmailer_table (messagekey_bulkmailer,messageid_bulkmailer,packetid_bulkmailer,receipients_bulkmailer,returnpath_bulkmailer,robot_bulkmailer,listname_bulkmailer, verp_bulkmailer, tracking_bulkmailer, merge_bulkmailer, priority_message_bulkmailer, priority_packet_bulkmailer, reception_date_bulkmailer, delivery_date_bulkmailer) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
                    SDM::quote($messagekey),
                    SDM::quote($msg_id),
                    SDM::quote($packetid),
                    SDM::quote($rcptasstring),
                    SDM::quote($from),
                    SDM::quote($robot),
                    SDM::quote($listname),
                    $verp,
                    SDM::quote($tracking),
                    $merge,
                    $priority_message,
                    $priority_for_packet,
                    $current_date,
                    $delivery_date
                )
                ) {
                Log::do_log(
                    'err',
                    'Unable to add packet %s of message %s to database spool',
                    $packetid,
                    $msg_id
                );
                return undef;
            }
        }
        $packet_rank++;
    }
    # last : unlock message in bulkspool_table so it is now possible to remove
    # this message if no packet has a ref on it
    unless (
        SDM::do_query(
            "UPDATE bulkspool_table SET lock_bulkspool='0' WHERE messagekey_bulkspool = %s",
            SDM::quote($messagekey)
        )
        ) {
        Log::do_log('err', 'Unable to unlock packet %s in bulkmailer_table',
            $messagekey);
        return undef;
    }
    return 1;
}

## remove file that are not referenced by any packet
sub purge_bulkspool {
    Log::do_log('debug', 'purge_bulkspool');

    unless (
        $sth = SDM::do_query(
            "SELECT messagekey_bulkspool AS messagekey FROM bulkspool_table LEFT JOIN bulkmailer_table ON messagekey_bulkspool = messagekey_bulkmailer WHERE messagekey_bulkmailer IS NULL AND lock_bulkspool = 0"
        )
        ) {
        Log::do_log('err',
            'Unable to check messages unreferenced by packets in database');
        return undef;
    }

    my $count = 0;
    while (my $key = $sth->fetchrow_hashref('NAME_lc')) {
        if (Bulk::remove_bulkspool_message('bulkspool', $key->{'messagekey'}))
        {
            $count++;
        } else {
            Log::do_log('err',
                'Unable to remove message (key = %s) from bulkspool_table',
                $key->{'messagekey'});
        }
    }
    $sth->finish;
    return $count;
}

sub remove_bulkspool_message {
    my $spool      = shift;
    my $messagekey = shift;

    my $table = $spool . '_table';
    my $key   = 'messagekey_' . $spool;

    unless (
        SDM::do_query(
            "DELETE FROM %s WHERE %s = %s", $table,
            $key,                           SDM::quote($messagekey)
        )
        ) {
        Log::do_log('err', 'Unable to delete %s %s from %s',
            $table, $key, $messagekey);
        return undef;
    }

    return 1;
}

# test the maximal message size the database will accept
sub store_test {
    my $value_test       = shift;
    my $divider          = 100;
    my $steps            = 50;
    my $maxtest          = $value_test / $divider;
    my $size_increment   = $divider * $maxtest / $steps;
    my $barmax           = $size_increment * $steps * ($steps + 1) / 2;
    my $even_part        = $barmax / $steps;
    my $rcpts            = 'nobody@cru.fr';
    my $from             = 'sympa-test@notadomain';
    my $robot            = 'notarobot';
    my $listname         = 'notalist';
    my $priority_message = 9;
    my $delivery_date    = time;
    my $verp             = 'on';
    my $merge            = 1;

    Log::do_log(
        'debug',
        'Bulk::store_test(<msg>,<rcpts>,from = %s,robot = %s,listname= %s,priority_message = %s,delivery_date= %s,verp = %s, merge = %s)',
        $from,
        $robot,
        $listname,
        $priority_message,
        $delivery_date,
        $verp,
        $merge
    );

    print "maxtest: $maxtest\n";
    print "barmax: $barmax\n";
    my $progress = Term::ProgressBar->new(
        {   name  => 'Total size transfered',
            count => $barmax,
            ETA   => 'linear',
        }
    );
    $priority_message = 9;

    my $messagekey = tools::md5_fingerprint(time());
    my $msg;
    $progress->max_update_rate(1);
    my $next_update = 0;
    my $total       = 0;

    my $result = 0;

    for (my $z = 1; $z <= $steps; $z++) {
        $msg = MIME::Base64::decode($msg);
        for (my $i = 1; $i <= 1024 * $size_increment; $i++) {
            $msg .= 'a';
        }
        $msg = MIME::Base64::encode($msg);
        my $time = time();
        $progress->message(
            sprintf
                "Test storing and removing of a %5d kB message (step %s out of %s)",
            $z * $size_increment,
            $z, $steps
        );
        #
        unless (
            SDM::do_query(
                "INSERT INTO bulkspool_table (messagekey_bulkspool, message_bulkspool, lock_bulkspool) VALUES (%s, %s, '1')",
                SDM::quote($messagekey),
                SDM::quote($msg)
            )
            ) {
            return (($z - 1) * $size_increment);
        }
        unless (Bulk::remove_bulkspool_message('bulkspool', $messagekey)) {
            Log::do_log(
                'err',
                'Unable to remove test message (key = %s) from bulkspool_table',
                $messagekey
            );
        }
        $total += $z * $size_increment;
        $progress->message(sprintf ".........[OK. Done in %.2f sec]",
            time() - $time);
        $next_update = $progress->update($total + $even_part)
            if $total > $next_update && $total < $barmax;
        $result = $z * $size_increment;
    }
    $progress->update($barmax)
        if $barmax >= $next_update;
    return $result;
}

## Return the number of remaining packets in the bulkmailer table.
sub get_remaining_packets_count {
    Log::do_log('debug3', 'get_remaining_packets_count');

    my $m_count = 0;

    unless (
        $sth = SDM::do_prepared_query(
            "SELECT COUNT(*) FROM bulkmailer_table WHERE lock_bulkmailer IS NULL"
        )
        ) {
        Log::do_log('err',
            'Unable to count remaining packets in bulkmailer_table');
        return undef;
    }

    my @result = $sth->fetchrow_array();

    return $result[0];
}

## Returns 1 if the number of remaining packets in the bulkmailer table
## exceeds
## the value of the 'bulk_fork_threshold' config parameter.
sub there_is_too_much_remaining_packets {
    Log::do_log('debug3', 'there_is_too_much_remaining_packets');
    my $remaining_packets = get_remaining_packets_count();
    if ($remaining_packets > Conf::get_robot_conf('*', 'bulk_fork_threshold'))
    {
        return $remaining_packets;
    } else {
        return 0;
    }
}

1;
