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

# categories как и всё остальное жёстко зашито в код - лучше ничего не удалять.
# Пример: фиты из группы Starter падают с припиской category=starter, в то время как все другие фиты идут в свою категорию, те category=dps, category=logi, ...
our $data = {
    "categories" => ["Logi", "Booster", "DPS", "Support", "Bastion", "Starter", "Alt", "CQC"],
    "ships" => {},
};
my $yaml_skills_raw = file_read('_skills.yaml');

if(defined $ARGV[0] && scalar(@ARGV) > 0){
    if($ARGV[0] eq 'check'){
        check_all_yaml();
    }
} else {
    read_ships();               # <- ships/*.yaml
    build_skills_yaml();        # -> backend/data/skills.yaml
    build_categories_yaml();    # -> backend/data/categories.yaml
    build_fits_dat();           # -> backend/data/fits.dat
    build_frontend_skillshow(); # -> frontend/src/Components/SkillDisplay.js
    check_all_yaml();
}

sub read_ships(){
    say '===================================';
    say '==  Load ship confis             ==';
    say '===================================';
    say '';
    opendir(my $dh, $pwd.'/ships') || die "Can't read dir: $!";
    while (readdir $dh) {
        next unless $_ =~ /\.yaml$/;
        
        my $y = yaml_read('ships/'.$_);

        $y->{path} = 'ships/'.$_;
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

        # next if $y->{active} == 0;
        if($y->{active} == 0){
            printf("[ %20.20s ]: Skip\n", $y->{path});
            next;
        }

        $data->{ships}->{$y->{name}} = $y;
        printf("[ %20.20s ]: Add\n", $y->{path});
    }
    closedir $dh;


}

sub check_all_yaml(){
    my $list = [
        # /backend/data/
        '_skills.yaml',
        'skills.yaml',
        'categories.yaml',
        'fitnotes.yaml',
        'modules.yaml',
        'skillplan.yaml',
        'tags.yaml',
    ];

    
    say '===================================';
    say '==  Check YAML Configs           ==';
    say '===================================';
    say 'Global:';
    say '';
    foreach my $fn(@$list){
        eval { yaml_read($fn) };
        $@ ?
            printf("[ %20.20s ]: ERROR\n\tNot correct skills data.\n\tErrMsg: %s\n", $fn, $@):
            printf("[ %20.20s ]: OK\n", $fn);
    }

    say '';
    say 'Ships section:';
    say '';

    opendir(my $dh, 'ships') || die "Can't read dir: $!";
    while (readdir $dh) {
        my $fn = 'ships/'.$_;
        next unless $fn =~ /\.yaml$/;

        eval {
            my $s = yaml_read($fn);
            $s->{skills} =~ s/\n/\n  /g;
            $s->{skills} = '  '.$s->{skills};
            Load($yaml_skills_raw . $s->{skills});
        };
        $@ ?
            printf("[ %20.20s ]: ERROR\n\tNot correct skills data.\n\tErrMsg: %s\n", $fn, $@):
            printf("[ %20.20s ]: OK\n", $fn);
    }
    close($dh);
}

sub build_frontend_skillshow(){

    # это нужно на случай запуска скриптов чисто для пересборки yaml файлов с фитами
    return unless(-e '../../frontend/src/Components/SkillDisplay.js');
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

        $html .= qq|<InputGroup>\n$loc_html</InputGroup>\n| if $loc_html ne '';
    }

    # $html = qq|<InputGroup></InputGroup>| if $html eq '';
    if($html eq ''){
        say 'build_frontend_skillshow(): html block is empty';
        say '------------------------------------------------';
        say '$ship_by_cat : '.Dumper($ship_by_cat);
        say '------------------------------------------------';
        exit;
    }

    # frontend/src/Components/SkillDisplay.js
    # <InputGroup> ... </InputGroup>
    my $SkillDisplay_js = file_read('../../frontend/src/Components/SkillDisplay.js');
    
    $SkillDisplay_js =~ s/\<InputGroup\>.*\<\/InputGroup\>/$html/s;

    file_write('../../frontend/src/Components/SkillDisplay.js', $SkillDisplay_js);
}

sub build_skills_yaml(){
    my $yaml_skills = Load($yaml_skills_raw);

    # тут лежат корректно прописанные скили
    my @skills = ();
    
    foreach my $cname( keys %{$yaml_skills->{categories}} ){
        foreach my $sname( @{$yaml_skills->{categories}->{$cname}} ){
            push @skills, $sname;
        }
    }

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
    say '===================================';
    say '==  Fits data\Doctrine           ==';
    say '===================================';
    my $doctrine = {};
    foreach my $shipname (keys %{$data->{ships}}){
        my $s = $data->{ships}->{$shipname};

        foreach my $fit(@{$s->{fits}}){
            unless(exists($doctrine->{$fit->{doctrine}}->{$shipname})){
                $doctrine->{$fit->{doctrine}}->{$shipname} = [];
            }
            push @{$doctrine->{$fit->{doctrine}}->{$shipname}}, $fit;
        }
    }

    # print Dumper($doctrine);

    open(my $fh, '>', 'fits.dat') || die "Can't open file: 'fits.dat'\nMsg: $!\n";
    foreach my $dname(keys %$doctrine){
        say "$dname : ";
        printf($fh qq|\n\n<font size="13" color="#ff00ff00">%s</font><font size="13" color="#ffff0000"><br></font><font size="13" color="#ffd98d00">\n|, $dname);

        while(my ($sname, $fits) = each (%{$doctrine->{$dname}})){
            foreach my $f (@$fits){
                say "\t".$f->{fit_name};
                printf($fh qq|<a href="%s">%s</a><br>\n|, $f->{fit_dna}, $f->{fit_name});
            }
        }

        print $fh qq|<br></font>\n|;
    }
    close($fh);
}

sub build_categories_yaml(){
    open(my $fh, '>', 'categories.yaml') || die "Can't open file: 'categories.yaml'\nMsg: $!\n";

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
    open(my $fh, '<', $fn) || die "Can't open file: $fn\nMsg: $!\n";
    while(my $l = <$fh>){
        $c.=$l;
    }
    close($fh);

    return $c;
}

sub file_write(){
    my $fn = shift;
    my $str = shift;
    
    open(my $fh, '>', $fn) || die "Can't open file: $fn\nMsg: $!\n";
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