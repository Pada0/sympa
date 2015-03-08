# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id$

# Sympa - SYsteme de Multi-Postage Automatique
#
# Copyright (c) 1997, 1998, 1999 Institut Pasteur & Christophe Wolfhugel
# Copyright (c) 1997, 1998, 1999, 2000, 2001, 2002, 2003, 2004, 2005,
# 2006, 2007, 2008, 2009, 2010, 2011 Comite Reseau des Universites
# Copyright (c) 2011, 2012, 2013, 2014, 2015 GIP RENATER
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

package Sympa::Archive;

use strict;
use warnings;
use Cwd qw();
use Digest::MD5 qw();
use Encode qw();
use HTML::Entities qw();

use Conf;
use Sympa::Log;
use Sympa::Message;
use tools;
use Sympa::Tools::File;

my $log = Sympa::Log->instance;

my $serial_number = 0;    # incremented on each archived mail

## RCS identification.

## Does the real job : stores the message given as an argument into
## the indicated directory.

sub store_last {
    my ($list, $msg) = @_;

    $log->syslog('debug2', '');

    return unless $list->is_archived();
    my $dir = $list->{'dir'} . '/archives';

    ## Create the archive directory if needed
    mkdir($dir, "0775") if !(-d $dir);
    chmod 0774, $dir;

    ## erase the last  message and replace it by the current one
    open(OUT, "> $dir/last_message");
    if (ref($msg)) {
        $msg->print(\*OUT);
    } else {
        print OUT $msg;
    }
    close(OUT);

}

## Lists the files included in the archive, preformatted for printing
## Returns an array.
sub list {
    my $name = shift;

    $log->syslog('debug', '(%s)', $name);

    my (@l, $i);

    unless (-d "$name") {
        $log->syslog('err', '(%s) Failed, no directory %s', $name, $name);
#      @l = ($msg::no_archives_available);
        return @l;
    }
    unless (opendir(DIR, "$name")) {
        $log->syslog('err', '(%s) Failed, cannot open directory %s',
            $name, $name);
#	@l = ($msg::no_archives_available);
        return @l;
    }
    foreach $i (sort readdir(DIR)) {
        next if ($i =~ /^\./o);
        next unless ($i =~ /^\d\d\d\d\-\d\d$/);
        my (@s) = stat("$name/$i");
        my $a = localtime($s[9]);
        push(@l, sprintf("%-40s %7d   %s\n", $i, $s[7], $a));
    }
    return @l;
}

sub scan_dir_archive {
    $log->syslog('debug3', '(%s, %s)', @_);
    my ($list, $month) = @_;

    my $dir =
        Conf::get_robot_conf($list->{'domain'}, 'arc_path') . '/'
        . $list->get_list_id();

    unless (opendir(DIR, "$dir/$month/arctxt")) {
        $log->syslog('info', 'Unable to open dir %s/%s/arctxt', $dir, $month);
        return undef;
    }

    my $all_msg = [];
    my $i       = 0;
    foreach my $file (sort readdir(DIR)) {
        next unless ($file =~ /^\d+$/);
        $log->syslog('debug', 'Start parsing message %s/%s/arctxt/%s',
            $dir, $month, $file);

        my $message =
            Sympa::Message->new_from_file("$dir/$month/arctxt/$file",
            context => $list);
        unless ($message) {
            $log->syslog('err',
                'Unable to create Message object from file %s', $file);
            return undef;
        }
        # Decrypt message if possible
        $message->smime_decrypt;

        $log->syslog('debug', 'MAIL object: %s', $message);

        $i++;
        my $msg = {};
        $msg->{'id'} = $i;

        $msg->{'subject'} = $message->{'decoded_subject'};
        $msg->{'from'}    = $message->get_decoded_header('From');
        $msg->{'date'}    = $message->get_decoded_header('Date');

        $msg->{'full_msg'} = $message->as_string;

        $log->syslog('debug', 'Adding message %s in archive to send',
            $msg->{'subject'});

        push @{$all_msg}, $msg;
    }
    closedir DIR;

    return $all_msg;
}

#####################################################
#  search_msgid
####################################################
#
# find a message in archive specified by arcpath and msgid
#
# IN : arcpath and msgid
#
# OUT : undef | #message in arctxt
#
####################################################

sub search_msgid {

    my ($dir, $msgid) = @_;

    $log->syslog('info', '(%s, %s)', $dir, $msgid);

    if ($msgid =~ /NO-ID-FOUND\.mhonarc\.org/) {
        $log->syslog('err', 'No message id found');
        return undef;
    }
    unless ($dir =~ /\d\d\d\d\-\d\d\/arctxt/) {
        $log->syslog('info', 'Dir %s look unproper', $dir);
        return undef;
    }
    unless (opendir(ARC, "$dir")) {
        $log->syslog('info',
            "archive::scan_dir_archive($dir, $msgid): unable to open dir $dir"
        );
        return undef;
    }
    chomp $msgid;

    foreach my $file (grep (!/\./, readdir ARC)) {
        next unless (open MAIL, "$dir/$file");
        while (<MAIL>) {
            last if /^$/;    #stop parse after end of headers
            if (/^Message-id:\s?<?([^>\s]+)>?\s?/i) {
                my $id = $1;
                if ($id eq $msgid) {
                    close MAIL;
                    closedir ARC;
                    return $file;
                }
            }
        }
        close MAIL;
    }
    closedir ARC;
    return undef;
}

sub exist {
    my ($name, $file) = @_;
    my $fn = "$name/$file";

    return $fn if (-r $fn && -f $fn);
    return undef;
}

# return path for latest message distributed in the list
sub last_path {
    $log->syslog('debug', '(%s)', @_);
    my $list = shift;

    return undef unless $list->is_archived();

    my $file = $list->{'dir'} . '/archives/last_message';
    return $file if -f $file;

    return undef;
}

## Load an archived message, returns the mhonarc metadata
## IN : file_path
sub load_html_message {
    my %parameters = @_;

    $log->syslog('debug2', $parameters{'file_path'});
    my %metadata;

    unless (open ARC, $parameters{'file_path'}) {
        $log->syslog(
            'err',
            'Failed to load message "%s": %m',
            $parameters{'file_path'}
        );
        return undef;
    }

    while (<ARC>) {
        last if /^\s*$/;    ## Metadata end with an emtpy line

        if (/^<!--(\S+): (.*) -->$/) {
            my ($key, $value) = ($1, $2);
            $value =
                Encode::encode_utf8(
                HTML::Entities::decode_entities(Encode::decode_utf8($value)));
            if ($key eq 'X-From-R13') {
                $metadata{'X-From'} = $value;
                ## Mhonarc protection of email addresses
                $metadata{'X-From'} =~ tr/N-Z[@A-Mn-za-m/@A-Z[a-z/;
                $metadata{'X-From'} =~ s/^.*<(.*)>/$1/g;   ## Remove the gecos
            }
            $metadata{$key} = $value;
        }
    }

    close ARC;

    return \%metadata;
}

sub clean_archive_directory {
    $log->syslog('debug2', '(%s, %s)', @_);
    my $robot          = shift;
    my $dir_to_rebuild = shift;

    my $arc_root = Conf::get_robot_conf($robot, 'arc_path');
    my $answer;
    $answer->{'dir_to_rebuild'} = $arc_root . '/' . $dir_to_rebuild;
    $answer->{'cleaned_dir'} = $Conf::Conf{'tmpdir'} . '/' . $dir_to_rebuild;
    unless (
        my $number_of_copies = Sympa::Tools::File::copy_dir(
            $answer->{'dir_to_rebuild'},
            $answer->{'cleaned_dir'}
        )
        ) {
        $log->syslog(
            'err',
            'Unable to create a temporary directory where to store files for HTML escaping (%s). Cancelling',
            $number_of_copies
        );
        return undef;
    }
    if (opendir ARCDIR, $answer->{'cleaned_dir'}) {
        my $files_left_uncleaned = 0;
        foreach my $file (readdir(ARCDIR)) {
            next if ($file =~ /^\./);
            $files_left_uncleaned++
                unless clean_archived_message(
                $robot, undef,
                $answer->{'cleaned_dir'} . '/' . $file,
                $answer->{'cleaned_dir'} . '/' . $file
                );
        }
        closedir DIR;
        if ($files_left_uncleaned) {
            $log->syslog('err',
                'HTML cleaning failed for %s files in the directory %s',
                $files_left_uncleaned, $answer->{'dir_to_rebuild'});
        }
        $answer->{'dir_to_rebuild'} = $answer->{'cleaned_dir'};
    } else {
        $log->syslog(
            'err',
            'Unable to open directory %s: %m',
            $answer->{'dir_to_rebuild'}
        );
        Sympa::Tools::File::del_dir($answer->{'cleaned_dir'});
        return undef;
    }
    return $answer;
}

sub clean_archived_message {
    $log->syslog('debug2', '(%s, %s, %s)', @_);
    my $robot  = shift;
    my $list   = shift;
    my $input  = shift;
    my $output = shift;

    my $message =
        Sympa::Message->new_from_file($input, context => ($list || $robot),);
    unless ($message) {
        $log->syslog('err', 'Unable to create a Message object with file %s',
            $input);
        return undef;
    }

    if ($message->clean_html) {
        if (open TMP, '>', $output) {
            print TMP $message->as_string;
            close TMP;
            return 1;
        } else {
            $log->syslog(
                'err',
                'Unable to create a tmp file to write clean HTML to file %s',
                $output
            );
            return undef;
        }
    } else {
        $log->syslog('err', 'HTML cleaning in file %s failed', $output);
        return undef;
    }
}

###########################
# convert a message to HTML.
#    result is stored in $destination_dir
#    attachement_url is used to link attachement
#
# NOTE: This might be moved to Site package as a mutative method.
# NOTE: convert_single_msg_2_html() was deprecated.
sub convert_single_message {
    my $that    = shift;    # List or Robot object
    my $message = shift;    # Message object or hashref
    my %opts    = @_;

    my $list;
    my $robot;
    my $listname;
    my $hostname;
    if (ref $that eq 'Sympa::List') {
        $list     = $that;
        $robot    = $that->{'domain'};
        $listname = $that->{'name'};
        $hostname = $that->{'admin'}{'host'};
    } elsif (!ref($that) and $that and $that ne '*') {
        $list     = '';
        $robot    = $that;
        $listname = '';
        $hostname = Conf::get_robot_conf($that, 'host');
    } else {
        die 'bug in logic.  Ask developer';
    }

    my $msg_as_string;
    if (ref $message eq 'Sympa::Message') {
        $msg_as_string = $message->as_string;
    } elsif (ref $message eq 'HASH') {
        $msg_as_string = $message->{'messageasstring'};
    } else {
        die 'bug in logic.  Ask developer';
    }

    my $destination_dir = $opts{'destination_dir'};
    my $attachement_url = $opts{'attachement_url'};

    my $mhonarc_ressources =
        tools::search_fullpath($that, 'mhonarc-ressources.tt2');
    unless ($mhonarc_ressources) {
        $log->syslog('notice', 'Cannot find any MhOnArc ressource file');
        return undef;
    }

    unless (-d $destination_dir) {
        unless (Sympa::Tools::File::mkdir_all($destination_dir, 0755)) {
            $log->syslog('err', 'Unable to create %s', $destination_dir);
            return undef;
        }
    }

    my $msg_file = $destination_dir . '/msg00000.txt';
    unless (open OUT, '>', $msg_file) {
        $log->syslog('notice', 'Could Not open %s', $msg_file);
        return undef;
    }
    print OUT $msg_as_string;
    close OUT;

    # mhonarc require du change workdir so this proc must retore it
    my $pwd = Cwd::getcwd();

    ## generate HTML
    unless (chdir $destination_dir) {
        $log->syslog('err', 'Could not change working directory to %s',
            $destination_dir);
        return undef;
    }

    my $tag      = get_tag($that);
    my $exitcode = system(
        Conf::get_robot_conf($robot, 'mhonarc'),
        '-single',
        '-rcfile'     => $mhonarc_ressources,
        '-definevars' => sprintf(
            "listname='%s' hostname=%s yyyy='' mois='' tag=%s",
            $listname, $hostname, $tag
        ),
        '-outdir'        => $destination_dir,
        '-attachmentdir' => $destination_dir,
        '-attachmenturl' => $attachement_url,
        '-umask'         => $Conf::Conf{'umask'},
        '-stdout'        => "$destination_dir/msg00000.html",
        '--',
        $msg_file
    ) >> 8;

    # restore current wd
    chdir $pwd;

    if ($exitcode) {
        $log->syslog(
            'err',
            'Command %s failed with exit code %d',
            Conf::get_robot_conf($robot, 'mhonarc'), $exitcode
        );
    }

    return 1;
}

=head2 sub get_tag(OBJECT $that)

Returns a tag derived from the listname.

=head3 Arguments 

=over 

=item * I<$that>, a List or Robot object.

=back 

=head3 Return 

=over 

=item * I<a character string>, corresponding to the 10 last characters of a 32 bytes string containing the MD5 digest of the concatenation of the following strings (in this order):

=over 4

=item - the cookie config parameter

=item - a slash: "/"

=item - name attribute of the I<$that> argument

=back 

=back

=cut 

sub get_tag {
    my $that = shift;

    my $name;
    if (ref $that eq 'Sympa::List') {
        $name = $that->{'name'};
    } elsif (!ref($that) and $that and $that ne '*') {
        $name = $that;
    } elsif (!ref($that)) {
        $name = '*';
    }

    return
        substr(Digest::MD5::md5_hex(join '/', $Conf::Conf{'cookie'}, $name),
        -10);
}

1;
