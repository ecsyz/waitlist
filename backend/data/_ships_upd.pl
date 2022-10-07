#!/usr/bin/perl
use strict;
# use warnings;
use experimental 'smartmatch';
use feature 'say';
use YAML::XS;
use FindBin;
use Data::Dumper;

$|++;

# https://yaml-multiline.info/
# https://codebeautify.org/yaml-parser-online

my $pwd = $FindBin::Bin;

our $data = {
    "categories" => ["Logi", "Booster", "DPS", "Support", "Bastion"],
    "ships" => {},
};
my $yaml_skills_raw = file_read('_skills.yaml');



opendir(my $dh, $pwd.'/ships') || die "Can't read dir: $!";
while (readdir $dh) {
    next unless $_ =~ /\.yaml$/;
    # next unless $_ =~ /Curse/i;
    
    my $y = yaml_read($pwd.'/ships/'.$_);
    $y->{path} = $pwd.'/ships/'.$_;
    $y->{file} = $_;

    if(exists $data->{ships}->{$y->{name}}) {
        printf("Setting for ship '%s' already exists.\nCurrent file: '%s'\nPredidushiy fail: '%s'\n", $y->{name}, $y->{path}, $data->{ships}->{$y->{name}}->{path});
        exit;
    }

    unless($y->{category} ~~ @{$data->{categories}}){
        printf(
            "Not correct category '%s' for ship '%s' in file '%s'\n", 
            $y->{category},
            $y->{name},
            $y->{path}
        );
        exit;
    }
    
    foreach my $fit(@{$y->{fits}}){
        $fit->{fit_name} = fit_name($fit);
    }

    $data->{ships}->{$y->{name}} = $y;
}
closedir $dh;

# print Dumper($data);

build_frontend_skillshow(); # -> frontend/src/Components/SkillDisplay.js
build_skills_yaml();        # -> backend/data/skills.yaml
build_categories_yaml();    # -> backend/data/categories.yaml
build_fits_dat();           # -> backend/data/fits.dat


sub build_frontend_skillshow(){
    # Format:
    # {
    #     <CATEGORY_NAME> => [<SHIP_NAME>, ...],
    #     ...
    # }
    my $ship_by_cat={};

    foreach my $sn (keys %{$data->{ships}}){
        my $s = $data->{ships}->{$sn};

        unless(exists($ship_by_cat->{$s->{category}})){
            $ship_by_cat->{$s->{category}} = [];
        }

        push @{$ship_by_cat->{$s->{category}}}, $s->{name};
    }

    my $html=''; 
    foreach my $c(keys %$ship_by_cat){
        my $loc_html='';

        foreach my $sn( @{$ship_by_cat->{$c}} ){
            # $loc_html .= sprintf(qq|<Button active={ship === "%1$s"} onClick={(evt) => setShip("%1$s")}>%1$s</Button>\n|, $sn);
            $loc_html .= qq|<Button active={ship === "$sn"} onClick={(evt) => setShip("$sn")}>$sn</Button>\n|;
        }

        $html .= qq|<InputGroup>\n$loc_html</InputGroup>\n|;
    }

    # say $html;
    # print Dumper($ship_by_cat);

    # frontend/src/Components/SkillDisplay.js
    # <InputGroup> ... </InputGroup>
    my $SkillDisplay_js = file_read($pwd.'../../frontend/src/Components/SkillDisplay.js');
    
    $SkillDisplay_js =~ s/\<InputGroup\>.*\<\/InputGroup\>/$html/s;

    file_write($pwd.'../../frontend/src/Components/SkillDisplay.js', $SkillDisplay_js);
}

sub build_skills_yaml(){
    my $yaml_skills = Load($yaml_skills_raw);

    # print Dumper($skills);

    # тут лежат корректно прописанные скили
    my @skills = ();
    

    foreach my $cname( keys %{$yaml_skills->{categories}} ){
        foreach my $sname( @{$yaml_skills->{categories}->{$cname}} ){
            push @skills, $sname;
        }
    }
    # print Dumper(\@skills);

    # перебираем все корабли
    foreach my $shipname (keys %{$data->{ships}}){
        my $s = $data->{ships}->{$shipname};
        my $ship_skills = {};
        my @bad_skills = ();
        # у каждого корабля проверяем skills, точнее парсим этот yaml конфиг
        eval {
            $ship_skills = Load($yaml_skills_raw . $s->{skills})->{$s->{name}};
            delete $ship_skills->{'<<'};
        };
        # eval error parse aka yaml parsing error
        if($@){
            die sprintf("Not correct skills data.\n\tFile: '%s'\n\tError: %s", $s->{path}, $@);
        }

        # убеждаемся что все сиклы, которые приписаны к кораблю, есть в глобальном списке категорий скилов
        foreach my $skill_name(keys %$ship_skills){
            # say "Skill: $skill_name";
            unless($skill_name ~~ @skills){
                push @bad_skills, $skill_name;
            }
        }

        if(scalar(@bad_skills) > 0){
            say sprintf("Ship skills not found in global skill categories.\n\tFile: '%s'\n\tMissing skills: %s", $s->{path}, join(', ', @bad_skills));
            exit;
        }
    }

    open(my $fh, '>', 'skills.yaml') || die "Can't open file: $!";
    say $fh $yaml_skills_raw;

    foreach my $sn (keys %{$data->{ships}}){
        my $t = $data->{ships}->{$sn}->{skills};
        $t =~ s/\n/\n  /g;
        say $fh '  '.$t;
    }

    close($fh);
}


sub build_fits_dat(){
    my $doctrine = {};
    foreach my $shipname (keys %{$data->{ships}}){
        my $s = $data->{ships}->{$shipname};

        foreach my $fit(@{$s->{fits}}){
            $doctrine->{$fit->{doctrine}}->{$shipname}=$fit;
        }
    }

    # print Dumper($doctrine);

    open(my $fh, '>', 'fits.dat') || die "Can't open file: $!";
    foreach my $dname(keys %$doctrine){
        printf($fh qq|\n\n<font size="13" color="#ff00ff00">%s</font><font size="13" color="#ffff0000"><br></font><font size="13" color="#ffd98d00">\n|, $dname);

        while(my ($sname, $f) = each (%{$doctrine->{$dname}})){
            printf($fh qq|<a href="%s">%s</a><br>\n|, $f->{fit_dna}, $f->{fit_name});
        }

        print $fh qq|<br></font>\n|;
    }
    close($fh);
}

sub build_categories_yaml(){
    open(my $fh, '>', 'categories.yaml') || die "Can't open file: $!";

    say $fh 'categories:';
    foreach my $cat(@{$data->{categories}}){
        say $fh '  - id: '.lc($cat);
        say $fh '    name: '.$cat;
    }
    say $fh '';

    say $fh 'rules:';
    foreach my $shipname (keys %{$data->{ships}}){
        my $s = $data->{ships}->{$shipname};

        # name: Bhaalgorn
        # category: Support
        say $fh '  - item: '.$s->{name};
        say $fh '    category: '.lc($s->{category});
    }
    say $fh '';

    close($fh);
}

sub yaml_read(){
    my $fn = shift;

    return Load( file_read($fn) );
}

sub file_read(){
    my $fn = shift;
    
    my $c='';
    open(my $fh, '<', $fn) || die "Can't open file: $!";
    while(my $l = <$fh>){
        $c.=$l;
    }
    close($fh);

    return $c;
}

sub file_write(){
    my $fn = shift;
    my $str = shift;
    
    open(my $fh, '>', $fn) || die "Can't open file: $!";
    print $fh $str;
    close($fh);
}

sub fit_name(){
    my $f = shift;

    my $fname = '';
    $fname = sprintf("%s\_%s", $f->{doctrine}, $f->{name});

    if(defined $f->{group} && $f->{group} ne ''){
        $fname .= '_'.$f->{group};
    }

    if(defined $f->{implants} && $f->{implants} ne ''){
        $fname .= '_'.$f->{implants};
    }

    return uc $fname;
}

sub c(){
    my $fn=shift;
    open(my $fh, '>', $fn);
    close($fh);
}