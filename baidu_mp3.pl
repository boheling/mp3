#!/usr/bin/perl
use strict;
use warnings;

use Getopt::Long;
use Pod::Usage;
use Config::Tiny;
use YAML qw(Dump Load DumpFile LoadFile);

use FindBin;
use Path::Class;
use File::stat;
use Encode qw(encode decode);
use LWP::UserAgent;
use WWW::Mechanize;
use Number::Format qw(:subs);

#----------------------------------------------------------#
# GetOpt section
#----------------------------------------------------------#
my $Config = Config::Tiny->new;
$Config = Config::Tiny->read("$FindBin::Bin/config.ini");

my $dir        = $Config->{main}->{dir};
my $overwrite  = $Config->{main}->{overwrite};
my $size_min = $Config->{main}->{size_min};
my $size_max = $Config->{main}->{size_max};

my $proxy    = $Config->{proxy}->{proxy};
my $username = $Config->{proxy}->{username};
my $password = $Config->{proxy}->{password};

my ( $url, $top500, $new100, $bang );

my $man  = 0;
my $help = 0;

GetOptions(
    'help|?'        => \$help,
    'man'           => \$man,
    'dir|d=s'       => \$dir,
    'overwrite|o=s' => \$overwrite,
    '500|5|t'       => \$top500,
    '100|1|n'       => \$new100,
    'bang|b'        => \$bang,
    'url|u=s'       => \$url,
) or pod2usage(2);

pod2usage(1) if $help;
pod2usage( -exitstatus => 0, -verbose => 2 ) if $man;

if ( !$url ) {
    if ($top500) {
        $url = $Config->{url}->{mp3topsong};
    }
    elsif ($new100) {
        $url = $Config->{url}->{newhits};
    }
    elsif ($bang) {
        $url = $Config->{url}->{bangping};
    }
    else {
        $url = $Config->{url}->{default};
    }
}

unless ( -e $dir ) {
    mkdir $dir, 0777
        or die "Cannot create \"$dir\" directory: $!";
}

#----------------------------------------------------------#
# run!!
#----------------------------------------------------------#
print "Address: $url\n";
print "Get pages...\n";
my $main_page_obj = get_page_obj($url);

print "Parsing song urls...\n";
my @songs = get_song_links($main_page_obj);
print "Find " . scalar @songs . " songs\n";

print "Getting every songs\n";
for (@songs) {
    get_the_song($_);
}

exit;

#----------------------------------------------------------#
# Subroutine
#----------------------------------------------------------#
sub get_page_obj {
    my $url = shift;

    my $mech           = WWW::Mechanize->new;
    my $composed_proxy = $proxy;
    if ($username) {
        $composed_proxy =~ s/(http:\/\/)/$1$username:$password@/;
    }
    $mech->proxy( [ 'http', 'ftp' ], $composed_proxy );
    $mech->get($url);

    return $mech;
}

sub get_song_links {
    my $mech = shift;
    my @song_links = $mech->find_all_links( url_regex => qr/.*\+.*$/ );
    my @songs;
    for (@song_links) {
        my $song_url  = $_->url;
        my $song_name = $_->text;
        push @songs, { url => $song_url, name => $song_name };
    }

    return @songs;
}

sub get_file_size {
    my $url = shift;

    my $ua = LWP::UserAgent->new( timeout => 10 );
    my $composed_proxy = $proxy;
    if ($username) {
        $composed_proxy =~ s/(http:\/\/)/$1$username:$password@/;
    }
    $ua->proxy( [ 'http', 'ftp' ], $composed_proxy );

    my $res = $ua->head($url);
    if ( $res->is_success ) {
        my $headers = $res->headers;
        return $headers->content_length;
    }

    return 0;
}

sub get_the_song {
    my $song = shift;

    my $mech = get_page_obj( $song->{url} );
    my @all_links = $mech->links( url_regex => qr/=baidusg/ );
    my @song_urls;
    for (@all_links) {
        my $link_url  = $_->url;
        my $link_text = $_->text;
        if (    $link_url =~ /=baidusg.*word=(mp3)/
            and $link_text eq $song->{name} )
        {
            push @song_urls, $link_url;
        }
    }

URL: for (@song_urls) {
        $mech->get($_);
        my $song_link = $mech->find_link( text_regex => qr/\.\.\./ );
        next URL if !defined $song_link;    # 未找到链接
        my $song_url  = $song_link->url;
        my $song_name = $song_link->text;
        $song_name =~ s/\s*\.+//;
        print "Downloading song: $song_name\n";
        print "From url: $song_url\n";

        # 格式应为mp3
        $song_url =~ /\.(\w+)$/;
        my $song_type = $1;
        next URL if $song_type ne 'mp3';

       # 若操作系统不是Windows，将目录名及文件名转换为utf-8
        my $filename = "$song_name.$song_type";
        $filename = file( $dir, $filename ) if $dir;
        if ( $^O ne "MSWin32" ) {
            $filename = decode( "cp936", $filename );
        }

        # 如果文件已存在，且$overwrite为否，则跳过当前文件
        if ( -e $filename and !$overwrite ) {
            print "$filename already exists.\n\n";
            last URL;
        }

        # 判断文件大小
        my $remote_size = get_file_size($song_url);
        print "Remote file size: ", format_bytes($remote_size), "\n";
        next if $remote_size == 4_510_966;    # an evil website
        next if $remote_size < $size_min;
        next if $remote_size > $size_max;

        get_file( $song_url, $filename );

        # 本地文件与远端文件大小不一致
        next URL if !-e $filename;
        if ( stat($filename)->size != $remote_size ) {
            unlink $filename;
            next URL;
        }

        print "$filename saved.\n\n";
        last;
    }

    return;
}

sub get_file {
    my $url      = shift;
    my $filename = shift;

    my $wget_cmd = "wget -t 1 -T 180 $url -O $filename";  # 不重试，限时
    $wget_cmd .= " -e http_proxy=$proxy"       if $proxy;
    $wget_cmd .= " --proxy-user=$username"     if $username;
    $wget_cmd .= " --proxy-password=$password" if $password;

    system($wget_cmd);
    return;
}

__END__

=head1 NAME

    baidu_mp3.pl - 百度MP3下载工具

=head1 SYNOPSIS
    perl baidu_mp3.pl
    
    realign.pl [options]
     Options:
       --help            brief help message
       --man             full documentation
       --500 -5 -t       下载歌曲TOP500(默认下载位置)
       --100 -1 -n       下载新歌TOP100
       --bang -b         下载中文金曲榜
       --url             指定下载url
       --dir             下载目录

=head1 OPTIONS

=over 8

=item B<-help>

Print a brief help message and exits.

=item B<-man>

Prints the manual page and exits.

=back

=head1 DESCRIPTION

B<This program> will read the given input file(s) and do someting
useful with the contents thereof.

=cut

