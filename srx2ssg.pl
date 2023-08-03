#!/usr/bin/perl

# use feature qw(switch);    # 打开given when结构支持
# no warnings 'experimental::smartmatch';
# use strict;
# use experimental qw(switch);
use warnings;
use Getopt::Long;
use Data::Printer;
use Net::IP::LPM;
use File::Basename;
use Spreadsheet::Read;
use Perl6::Slurp;

# 输入输出报错支持中文
# use open ":encoding(gbk)", ":std";
binmode( STDOUT, ":encoding(gbk)" );
binmode( STDIN,  ":encoding(gbk)" );
binmode( STDERR, ":encoding(gbk)" );

sub usage {
    my $err = shift and select STDERR;
    print
"usage: $0 [-c srx config file] [-n net] [-o file] [-s srx to ssg service mapping table] srx file\n",
      "\t-c file        srx configuration file\n",
      "\t-i number      ssg first policy id\n",
      "\t-n             subnet should be find out\n",
      "\t-o file        ssg configuration output file\n",
      "\t-s file        srx to ssg service mapping file\n",
      "\t-h print usage\n";
    exit $err;
}    # 使用方法

my $opt_c;
my $opt_i;
my $opt_n;
my $opt_o;
my $opt_s;

GetOptions(
    "help|h"      => sub { usage(0); },
    "c|config:s"  => \$opt_c,
    "i|index:i"   => \$opt_i,
    "n|nets=s@"   => \$opt_n,             # "@"表示接收多个参数
    "o|output:s"  => \$opt_o,
    "s|service=s" => \$opt_s,

) or usage(1);

sub srx2ssg {
    my ( $ref_elements, $ref_policies, $ref_svc_map ) = @_;
    my @srx_elements = @{$ref_elements};
    my @srx_policies = @{$ref_policies};
    my $term_name;       # 存放term名称，用于添加新term和追加term内容
    my @ssg_elements;    # 存放address book和service group
    my %ssg_policies;    # 存放策略元素，如source-address,application, then
    my %ssg_services;    # 存放service和service group,用于END{}后期处理

    # 使用ssg的服务名称替换srx的服务名称
    # 首先将存储策略的数组保存到标量中，替换后再还原成数组
    my $tmp_srx_policies = join( ",", @srx_policies );
    while ( my ( $key, $value ) = each(%$ref_svc_map) ) {
        $tmp_srx_policies =~ s/application $key/application $value/g;
    }
    @srx_policies = split /,/, $tmp_srx_policies;

    # 转换策略元素到ssg格式
    foreach (@srx_elements) {
        if ( /address-book/ && /global/ ) {
            if (/address-set/) {
                my ( $zone, $address_set, $address_name ) =
                  ( split /\s+/ )[ 3, 5, 7 ];
                $zone = ucfirst($zone);
                push @ssg_elements,
                  "set group address $zone $address_set add $address_name";
            }
            else {
                my ( $zone, $address_name, $address ) =
                  ( split /\s+/ )[ 3, 5, 6 ];
                $zone = ucfirst($zone);
                push @ssg_elements, "set address $zone $address_name $address";
            }
            next;
        }
        elsif (/address-book/) {
            if (/address-set/) {
                my ( $zone, $address_set, $address_name ) =
                  ( split /\s+/ )[ 4, 7, 9 ];
                push @ssg_elements,
                  "set group address $zone $address_set add $address_name";
            }
            else {
                my ( $zone, $address_name, $address ) =
                  ( split /\s+/ )[ 4, 7, 8 ];
                $zone = ucfirst($zone);
                push @ssg_elements, "set address $zone $address_name $address";
            }
            next;
        }
        elsif (/applications/) {

            # application-set比较简单，直接放入ssg_elements数组即可直接输出
            if (/application-set/) {
                my ( $app_set_name, $app_name ) = ( split /\s+/ )[ 3, 5 ];
                push @ssg_elements,
                  "set group service $app_set_name add $app_name";
                next;
            }
            else {
                # 没有term的处理方式
                if ( !/\bterm\b/ ) {
                    my ( $app_name, $service1, $service2 ) =
                      ( split /\s+/ )[ 3, 4, 5 ];
                    $service1 =~ s/source-port/src-port/;
                    $service1 =~ s/destination-port/dst-port/;

                    # 判断是否为新的hash元素，是新元素则直接赋值，反之则追加新值
                    if ( exists( $ssg_services{$app_name} ) ) {
                        my $value = $ssg_services{$app_name}->[0];
                        $ssg_services{$app_name}->[0] =
                          "$value $service1 $service2";

                        # p $ssg_services{$app_name}->[0];
                        # p $ssg_services{$app_name};
                    }
                    else {
                        $ssg_services{$app_name}->[0] = "$service1 $service2";

                        # p $ssg_services{$app_name}->[0];
                    }
                    next;
                }

                # 有term的处理方式
                else {
                    my ( $app_name, $tmp_term_name, $service1, $service2 ) =
                      ( split /\s+/ )[ 3, 5, 6, 7 ];
                    $service1 =~ s/source-port/src-port/;
                    $service1 =~ s/destination-port/dst-port/;

                    # 当遇到新的application时直接传入五元组内容
                    # 将元组内容赋值给指向hash的数组
                    if ( !exists( $ssg_services{$app_name} ) ) {
                        $ssg_services{$app_name}->[0] = "$service1 $service2";

                        # p $ssg_services{$app_name}->[0];
                    }

                    # 如果新的term名和旧的term名一样，则已经存在该app_name的hash
                    # 此时只需将相关值追加入最后一个数组元素中
                    elsif ( $tmp_term_name eq $term_name ) {
                        my $value = $ssg_services{$app_name}->[-1];
                        $ssg_services{$app_name}->[-1] =
                          "$value $service1 $service2";
                    }

                    # 同一个application下新的term
                    elsif ( exists( $ssg_services{$app_name} )
                        && $tmp_term_name ne $term_name )
                    {
                        push @{ $ssg_services{$app_name} },
                          "$service1 $service2";
                    }

                    # 更新term名，用于下次比较
                    $term_name = ( split /\s+/ )[5];
                    next;
                }
            }
        }
    }
    foreach (@srx_policies) {

        # 策略处理时使用哈希到哈希的引用，同时被引用的哈希为哈希数组即哈希的值为数组
        # global和常规策略的不同在于元素的位置不同，其他一样
        if (/\bpolicies global\b/) {
            my ( $policy_name, $element_name, $service );
            if (/\bthen\b/) {
                ( $policy_name, $element_name, $service ) =
                  ( split /\s+/ )[ 5, 6, -1 ];
            }
            else {
                ( $policy_name, $element_name, $service ) =
                  ( split /\s+/ )[ 5, 7, -1 ];
            }

            push @{ $ssg_policies{$policy_name}->{$element_name} }, $service;

            # p @{ $ssg_policies{$policy_name}->{$element_name} };
            # p %{ $ssg_policies{$policy_name} };
            next;
        }
        else {
            my ( $src_zone, $dst_zone, $policy_name, $element_name, $service );
            if (/\bthen\b/) {
                ( $src_zone, $dst_zone, $policy_name, $element_name, $service )
                  = ( split /\s+/ )[ 4, 6, 8, 9, -1 ];
            }
            else {
                ( $src_zone, $dst_zone, $policy_name, $element_name, $service )
                  = ( split /\s+/ )[ 4, 6, 8, 10, -1 ];
            }
            unless ( exists( $ssg_policies{$policy_name} ) ) {
                $ssg_policies{$policy_name}->{"src-zone"} = $src_zone;
                $ssg_policies{$policy_name}->{"dst-zone"} = $dst_zone;
            }
            push @{ $ssg_policies{$policy_name}->{$element_name} }, $service;

            # p @{ $ssg_policies{$policy_name}->{$element_name} };
            # p %{ $ssg_policies{$policy_name} };
            next;
        }
    }
    return ( \@ssg_elements, \%ssg_services, \%ssg_policies );
}

# 根据find_net_config给出的策略，找出相应的元素定义条目
sub find_elements {
    my (
        @address_book,      @applications, @final_address_book,
        @final_application, @final_elements
    );
    my ( $ref_finded_policies, $ref_all_config_data ) = @_;
    my @finded_policies = @{$ref_finded_policies};
    my @all_config_data = @{$ref_all_config_data};

    foreach (@finded_policies) {
        if (/\b(source|destination)-address\b/) {
            push @address_book, ( split /\s+/ )[-1];
            next;
        }
        elsif (/\bapplication\b/) {
            push @applications, ( split /\s+/ )[-1];
            next;
        }
    }

    # 去重
    my @sort_address_book = do {
        my %tmp_src;
        grep { !$tmp_src{$_}++ } @address_book;
    };
    my @sort_application = do {
        my %tmp_src;
        grep { !$tmp_src{$_}++ } @applications;
    };

    print scalar @sort_address_book;
    print "\n";
    print scalar @sort_application;
    print "\n";
    foreach my $addr (@sort_address_book) {
        foreach (@all_config_data) {
            if (/security address-book .* \b$addr\b/) {
                push @final_address_book, $_;
            }
        }
    }
    foreach my $app (@sort_application) {
        foreach (@all_config_data) {
            if (/applications .* \b$app\b/) {
                push @final_application, $_;
            }
        }
    }
    return @final_elements = ( @final_address_book, @final_application );
}

# 按照给定的网段找出网段内的相应策略
sub find_net_config {
    my ( $ref_nets, $ref_all_config_data ) = @_;
    my $source_matched = "off";
    my $dest_matched   = "off";
    my $then_status    = "off";
    my $prefix_match   = Net::IP::LPM->new();
    my @nets           = split( /,/, join( ',', @{$ref_nets} ) );    #支持,分割的参数列表
    my @source_polcies;
    my @dest_polcies;
    my @source_matched_polcies;
    my @dest_matched_polcies;
    my @applications;
    my @final_policies;
    my @all_config_data = @{$ref_all_config_data};

    foreach (@nets) {
        $prefix_match->add( $_, "net-$_" );    # 将要查找的网段添加进database
    }

    foreach (@all_config_data) {

        # 判断是否为一条新策略，并根据是否已经匹配子网清除相关状态
        if ( $then_status eq "on"
            && !/\bthen\b/ )
        {
            $then_status = "off";
            if ( $source_matched eq "on" or $dest_matched eq "on" ) {

                $dest_matched   = "off";
                $source_matched = "off";
            }
        }
        if (/\bsecurity policies\b/) {
            if (/\bsource-address\b/) {
                push @source_polcies, $_;
                my $address = ( split /\s+/ )[-1];
                if ( $address =~ /_/ ) {
                    $address = ( split /_/, $address )[-1];
                }
                if ( $address =~ /\// ) {
                    $address = ( split /\//, $address )[0];
                }
                if (   $address eq "any"
                    or $prefix_match->lookup($address) )
                {
                    $source_matched = "on";
                    push @source_matched_polcies, $_;
                }
                next;
            }
            elsif (/\bdestination-address\b/) {
                push @dest_polcies, $_;
                my $address = ( split /_/ )[-1];
                if ( $address =~ /_/ ) {
                    $address = ( split /_/, $address )[-1];
                }
                if ( $address =~ /\// ) {
                    $address = ( split /\//, $address )[0];
                }
                if (   $address eq "on"
                    or $prefix_match->lookup($address) )
                {
                    $dest_matched = "on";
                    push @dest_matched_polcies, $_;
                }
                next;
            }
            elsif (/\bapplication\b/) {
                push @applications, $_;
                next;
            }
            elsif (/\bthen (permit|deny)\b/) {
                $then_status = "on";
                if ( $source_matched eq "on" ) {
                    push @final_policies,
                      (
                        @source_matched_polcies, @dest_polcies,
                        @applications,           $_,
                      );
                }
                elsif ( $dest_matched eq "on" ) {
                    push @final_policies,
                      (
                        @source_polcies, @dest_matched_polcies,
                        @applications,   $_,
                      );
                }
                undef @source_polcies;
                undef @source_matched_polcies;
                undef @dest_polcies;
                undef @dest_matched_polcies;
                undef @applications;
                next;
            }
            elsif ( /\bthen\b/ && $source_matched eq "on"
                or $dest_matched eq "on" )
            {
                push @final_policies, $_;
            }
        }
    }
    return @final_policies;
}

my @srx_config_file;
my %services;
my $policy_id;    # ssg policy id初始值，可以用户指定或者默认设置，默认为8000

my $services_file = Spreadsheet::Read->new($opt_s)
  or die "无法打开$opt_s";

my $sheet = $services_file->sheet("sheet1");

# 读取exel每一行数据，并创建services哈希表
foreach my $row ( $sheet->{minrow} .. $sheet->{maxrow} ) {
    my @data = $sheet->cellrow($row);
    $data[0]  =~ s/\s+$//;
    $data[-1] =~ s/\s+$//;
    $services{ $data[0] } = $data[-1];
}

# 打开srx配置文件
if ($opt_c) {
    open my $config, '<', $opt_c
      or die "can't open file:$!\n";    #open the config filehandle
        # @srx_config_file = do { local $/; <$config> };
        # @srx_config_file = <$config>;
        # chomp @srx_config_file;
    @srx_config_file = slurp $config;
    chomp @srx_config_file;
    close $config;
}
else {
    open my $config, '<', $ARGV[0]
      or die "can't open file:$! $ARGV[0]\n";    #open the config filehandle
    @srx_config_file = slurp $config;
    chomp @srx_config_file;
    close $config;
}

# 设置policy id
if ($opt_i) {
    $policy_id = $opt_i;
}
else {
    $policy_id = 8000;
}

# 获得srx策略内容
my @policies = find_net_config( \@$opt_n, \@srx_config_file );

# 获得srx元素内容
my @elements = find_elements( \@policies, \@srx_config_file );

# 获取ssg格式的address-book,group service存储在ssg_addresses_service中,
# service元素存储在%ssg_services中,policy元素存储在ssg_policies中
my ( $ssg_addresses_service, $ssg_services_final, $ssg_policies_final ) =
  srx2ssg( \@elements, \@policies, \%services );

# 输出ssg格式的group address, address和group service
foreach ( @{$ssg_addresses_service} ) {
    print "$_\n";
}

# 输出ssg格式的service
foreach my $svc_name ( keys %{$ssg_services_final} ) {
    for ( my $i = 0 ; $i < @{ $ssg_services_final->{$svc_name} } ; $i++ ) {
        if ( $i == 0 ) {
            print
"set service $svc_name ${ $ssg_services_final->{$svc_name}}[$i]\n";
        }
        else {
            ${ $ssg_services_final->{$svc_name} }[$i] =~ s/protocol/+/;
            print
"set service $svc_name ${ $ssg_services_final->{$svc_name}}[$i]\n";
        }
    }
}

# 输出ssg格式的service
foreach my $policy_name ( keys %{$ssg_policies_final} ) {

    # 常规策略
    if ( exists( $ssg_policies_final->{$policy_name}->{"src-zone"} ) ) {
        print
qq(set policy id $policy_id name $policy_name from $ssg_policies_final->{$policy_name}->{"src-zone"} to $ssg_policies_final->{$policy_name}->{"dst-zone"} $ssg_policies_final->{$policy_name}->{"source-address"}->[0] $ssg_policies_final->{$policy_name}->{"destination-address"}->[0] $ssg_policies_final->{$policy_name}->{"application"}->[0] $ssg_policies_final->{$policy_name}->{"then"}->[0]\n);
        print "set policy id $policy_id\n";
        foreach ( @{ $ssg_policies_final->{$policy_name}->{"source-address"} } )
        {
            print "set src-address $_\n";
        }
        foreach (
            @{ $ssg_policies_final->{$policy_name}->{"destination-address"} } )
        {
            print "set dst-address $_\n";
        }
        foreach ( @{ $ssg_policies_final->{$policy_name}->{"application"} } ) {
            print "set service $_\n";
        }
    }

    # global策略
    else {
        print
qq(set policy global id $policy_id name $policy_name $ssg_policies_final->{$policy_name}->{"source-address"}->[0] $ssg_policies_final->{$policy_name}->{"destination-address"}->[0] $ssg_policies_final->{$policy_name}->{"application"}->[0] $ssg_policies_final->{$policy_name}->{"then"}->[0]\n);
        print "set policy id $policy_id\n";
        foreach ( @{ $ssg_policies_final->{$policy_name}->{"source-address"} } )
        {
            print "set src-address $_\n";
        }
        foreach (
            @{ $ssg_policies_final->{$policy_name}->{"destination-address"} } )
        {
            print "set dst-address $_\n";
        }
        foreach ( @{ $ssg_policies_final->{$policy_name}->{"application"} } ) {
            print "set service $_\n";
        }
    }
    print "exit\n";
    $policy_id++;
}

=pod

%ssg_services保存service名和service具体内容
ie.
%ssg_services = {
    TCP_UDP_8080 => [0] protocol tcp src-port 0-65535 dst-port 8080,
    TCP_UDP_8080 => [1] protocol udp src-port 0-65535 dst-port 8080
}
%ssg_policies = {
    policy_permit_ssh_global =>{
        source-address      =   [0] host_192.168.1.1
                                [1] net_30.22.198.0/24
        destination-address =   [0] host_10.1.10.1
                                [1] net_30.98.108.0/24
        application         =   [0] TCP_UDP_8080
                                [1] any
                                [2] SSH 
        then                =   [0] permit
    }
    policy_permit_ssh       =>{
        from-zone           =   [0] Trust
        to-zone             =   [0] Untrust
        source-address      =   [0] host_192.168.1.1
                                [1] net_30.22.198.0/24
        destination-address =   [0] host_10.1.10.1
                                [1] net_30.98.108.0/24
        application         =   [0] TCP_UDP_8080
                                [1] any
                                [2] SSH 
        then                =   [0] deny
    }
}
=cut
