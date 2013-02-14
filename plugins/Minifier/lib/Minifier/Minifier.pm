package Minifier::Minifier;
use strict;

sub _pre_run {
    my $app = MT->instance;
    if ( $app->param( '__mode' ) eq 'save_cfg_system_general' ) {
        if ( $ENV{ SERVER_SOFTWARE } =~ /Microsoft-IIS/ ) {
            return 1;
        }
        if (! $app->user->is_superuser ) {
            $app->return_to_dashboard( permission => 1 );
        }
        if ( $app->param( 'use_minifier' ) ) {
            my $static_file_path = __chomp_dir( $app->static_file_path );
            require File::Spec;
            my $htaccess = File::Spec->catfile( $static_file_path, '.htaccess' );
            my $dir = File::Spec->catdir( $static_file_path, 'minify_2' );
            if (-d $dir ) {
                if (! -f $htaccess ) {
                    my $tmpl = <<'MTML';
<IfModule mod_rewrite.c>
  RewriteEngine on
  RewriteRule ^([^?]+\.(css|js))$ <$MTStaticWebPath abs_addslash="1"$>minify_2/min/f=<$MTStaticWebPath abs_addslash="1" cut_firstslash="1"$>$1 [NC,L]
</IfModule>
MTML
                    require MT::Template;
                    require MT::Builder;
                    require MT::Template::Context;
                    my $ctx = MT::Template::Context->new;
                    my $build = MT::Builder->new;
                    my $tokens = $build->compile( $ctx, $tmpl )
                        or return $app->error( $app->translate(
                            "Parse error: [_1]", $build->errstr ) );
                    defined( my $data = $build->build( $ctx, $tokens ) )
                        or return $app->error( $app->translate(
                            "Build error: [_1]", $build->errstr ) );
                    require MT::FileMgr;
                    my $fmgr = MT::FileMgr->new( 'Local' ) or die MT::FileMgr->errstr;
                    $fmgr->put_data( $data, $htaccess );
                }
            }
        }
    }
    return 1;
}

sub _cfg_system_general {
    my ( $cb, $app, $param, $tmpl ) = @_;
    my $plugin = MT->component( 'Minifier' );
    if ( $ENV{ SERVER_SOFTWARE } =~ /Microsoft-IIS/ ) {
        return 1;
    }
    my $static_file_path = __chomp_dir( $app->static_file_path );
    my $dir = File::Spec->catdir( $static_file_path, 'minify_2' );
    if (! -d $dir ) {
        return;
    }
    my $pointer_field;
    if ( MT->version_id =~ /^5\.0/ ) {
        $pointer_field = $tmpl->getElementById( 'system_performance_logging' );
    } else {
        $pointer_field = $tmpl->getElementById( 'system-performance-logging' );
    }
    my $nodeset = $tmpl->createElement( 'app:setting', { id => 'use_minifier',
                                                         label => $plugin->translate( 'Minifier' ) ,
                                                         show_label => 1,
                                                         content_class => 'field-content-text' } );
    my $innerHTML = <<MTML;
<__trans_section component="Minifier">
        <input type="checkbox" id="use_minifier" name="use_minifier"<mt:if name="use_minifier"> checked="checked"</mt:if> class="cb" /> <label for="use_minifier"><__trans phrase="Minifying JavaScript and CSS code in mt-static"></label>
</__trans_section>
MTML
    $nodeset->innerHTML( $innerHTML );
    $tmpl->insertAfter( $nodeset, $pointer_field );
    require File::Spec;
    my $htaccess = File::Spec->catfile( $static_file_path, '.htaccess' );
    require MT::FileMgr;
    my $fmgr = MT::FileMgr->new( 'Local' ) or die MT::FileMgr->errstr;
    unless ( $fmgr->exists( $htaccess ) ) {
       return '';
    }
    my $cfg = $fmgr->get_data( $htaccess );
    if ( $cfg ) {
        my $search = quotemeta( 'minify_2/min/f=' );
        if ( $cfg =~ /$search/ ) {
            $param->{ use_minifier } = 1;
        }
    }
    return 1;
}

sub _hdlr_html_compressor {
    my ( $ctx, $args, $cond ) = @_;
    my $out = $ctx->stash( 'builder' )->build( $ctx, $ctx->stash( 'tokens' ), $cond );
    $out = MT->instance->translate_templatized( $out );
    require HTML::Packer;
    my $packer = HTML::Packer->init();
    $out = $packer->minify( \$out, $args );
    return $out;
}

sub _cb_gzip {
    my ( $cb, %args ) = @_;
    if ( MT->config( 'content2gzip' ) ) {
        my $content = $args{ content };
        my $file = $args{ file };
        my @extentions = split( /,/, MT->config( 'content2gzipextensions' ) );
        my $extension = '';
        if ( $file =~ /\.([^.]+)\z/ ) {
            $extension = lc( $1 );
        } else {
            return
        }
        if ( grep( /^$extension$/, @extentions ) ) {
            require IO::Compress::Gzip;
            my $output;
            my $data = $content = MT::I18N::utf8_off( $$content );
            IO::Compress::Gzip::gzip( \$data, \$output, Minimal => 1 );
            require MT::FileMgr;
            my $fmgr = MT::FileMgr->new( 'Local' );
            $fmgr->put_data( $output, $file . '.gz', 'upload' );
        }
    }
}

sub _cb_delete_archive {
    my ( $cb, $file, $at, $entry ) = @_;
    if ( MT->config( 'content2gzip' ) ) {
        my @extentions = split( /,/, MT->config( 'content2gzipextensions' ) );
        my $extension = '';
        if ( $file =~ /\.([^.]+)\z/ ) {
            $extension = lc( $1 );
        } else {
            return
        }
        if ( grep( /^$extension$/, @extentions ) ) {
            require MT::FileMgr;
            my $fmgr = MT::FileMgr->new( 'Local' );
            if ( $fmgr->exists( $file . '.gz' ) ) {
                $fmgr->delete( $file . '.gz' );
            }
        }
    }
}

sub _hdlr_css_compressor {
    my ( $ctx, $args, $cond ) = @_;
    my $out = _hdlr_pass_tokens( @_ );
    $out = MT->instance->translate_templatized( $out );
    require CSS::Minifier;
    $out = CSS::Minifier::minify( input => $out );
    return $out;
}

sub _hdlr_js_compressor {
    my ( $ctx, $args, $cond ) = @_;
    my $out = _hdlr_pass_tokens( @_ );
    $out = MT->instance->translate_templatized( $out );
    require JavaScript::Minifier;
    $out = JavaScript::Minifier::minify( input => $out );
    return $out;
}

sub _hdlr_pass_tokens {
    my ( $ctx, $args, $cond ) = @_;
    $ctx->stash( 'builder' )->build( $ctx, $ctx->stash( 'tokens' ), $cond );
}

sub _fltr_abs_addslash {
    my ( $text, $arg, $ctx ) = @_;
    $text = __add_slash( $text );
    $text =~ s!^https{0,1}://.*?(/)!$1!;
    return $text;
}

sub _fltr_cut_firstslash {
    my ( $text, $arg, $ctx ) = @_;
    $text =~ s!^/!!;
    return $text;
}

sub __add_slash {
    my $path = shift;
    return $path if $path eq '/';
    if ( $path =~ m!^https?://! ) {
        $path =~ s{/*\z}{/};
        return $path;
    }
    $path = __chomp_dir( $path );
    $path .= '/';
    return $path;
}

sub __chomp_dir {
    my $dir = shift;
    require File::Spec;
    my @path = File::Spec->splitdir( $dir );
    $dir = File::Spec->catdir( @path );
    return $dir;
}

1;