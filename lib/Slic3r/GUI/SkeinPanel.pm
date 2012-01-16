package Slic3r::GUI::SkeinPanel;
use strict;
use warnings;
use utf8;

use File::Basename qw(basename dirname);
use Wx qw(:sizer :progressdialog wxOK wxICON_INFORMATION wxICON_WARNING wxICON_ERROR wxID_OK wxFD_OPEN
    wxFD_SAVE wxDEFAULT wxNORMAL);
use Wx::Event qw(EVT_BUTTON);
use base 'Wx::Panel';

my $last_dir;
our $last_config;

sub new {
    my $class = shift;
    my ($parent) = @_;
    my $self = $class->SUPER::new($parent, -1);
    
    my %panels = (
        printer => {
            title => 'Printer',
            options => [qw(nozzle_diameter print_center use_relative_e_distances extrusion_axis z_offset)],
        },
        filament => {
            title => 'Filament',
            options => [qw(filament_diameter extrusion_multiplier temperature)],
        },
        print_speed => {
            title => 'Print speed',
            options => [qw(perimeter_speed small_perimeter_speed infill_speed solid_infill_speed bridge_speed)],
        },
        speed => {
            title => 'Other speed settings',
            options => [qw(travel_speed bottom_layer_speed_ratio)],
        },
        accuracy => {
            title => 'Accuracy',
            options => [qw(layer_height first_layer_height_ratio infill_every_layers)],
        },
        print => {
            title => 'Print settings',
            options => [qw(perimeters solid_layers fill_density fill_angle fill_pattern solid_fill_pattern)],
        },
        retract => {
            title => 'Retraction',
            options => [qw(retract_length retract_lift retract_speed retract_restart_extra retract_before_travel)],
        },
        skirt => {
            title => 'Skirt',
            options => [qw(skirts skirt_distance skirt_height)],
        },
        transform => {
            title => 'Transform',
            options => [qw(scale rotate duplicate_x duplicate_y duplicate_distance)],
        },
        gcode => {
            title => 'Custom GCODE',
            options => [qw(start_gcode end_gcode)],
        },
        extrusion => {
            title => 'Extrusion',
            options => [qw(extrusion_width_ratio bridge_flow_ratio)],
        },
        output => {
            title => 'Output',
            options => [qw(output_filename_format)],
        },
        vibration => {
            title => 'Anti-Vibration',
            options => [qw(vibration_move_threshold vibration_speed_ratio)],
        },

    );
    $self->{panels} = \%panels;
    
    my $tabpanel = Wx::Notebook->new($self, -1, Wx::wxDefaultPosition, Wx::wxDefaultSize, &Wx::wxNB_TOP);
    my $make_tab = sub {
        my @cols = @_;
        
        my $tab = Wx::Panel->new($tabpanel, -1);
        my $sizer = Wx::BoxSizer->new(wxHORIZONTAL);
        foreach my $col (@cols) {
            my $vertical_sizer = Wx::BoxSizer->new(wxVERTICAL);
            for my $optgroup (@$col) {
                my $optpanel = Slic3r::GUI::OptionsGroup->new($tab, %{$panels{$optgroup}});
                $vertical_sizer->Add($optpanel, 0, wxEXPAND | wxALL, 10);
            }
            $sizer->Add($vertical_sizer);
        }
        
        $tab->SetSizer($sizer);
        return $tab;
    };
    
    my @tabs = (
        $make_tab->([qw(transform accuracy skirt)], [qw(print retract)]),
        $make_tab->([qw(printer filament)], [qw(print_speed speed)]),
        $make_tab->([qw(gcode)]),
        $make_tab->([qw(extrusion)], [qw(output)], [qw(vibration)]),
    );
    
    $tabpanel->AddPage($tabs[0], "Print Settings");
    $tabpanel->AddPage($tabs[1], "Printer and Filament");
    $tabpanel->AddPage($tabs[2], "Start/End GCODE");
    $tabpanel->AddPage($tabs[3], "Advanced");
        
    my $buttons_sizer;
    {
        $buttons_sizer = Wx::BoxSizer->new(wxHORIZONTAL);
        
        my $slice_button = Wx::Button->new($self, -1, "Slice...");
        $buttons_sizer->Add($slice_button, 0);
        EVT_BUTTON($self, $slice_button, sub { $self->do_slice });
        
        my $save_button = Wx::Button->new($self, -1, "Save configuration...");
        $buttons_sizer->Add($save_button, 0);
        EVT_BUTTON($self, $save_button, sub { $self->save_config });
        
        my $load_button = Wx::Button->new($self, -1, "Load configuration...");
        $buttons_sizer->Add($load_button, 0);
        EVT_BUTTON($self, $load_button, sub { $self->load_config });
        
        my $text = Wx::StaticText->new($self, -1, "Remember to check for updates at http://slic3r.org/\nVersion: $Slic3r::VERSION", Wx::wxDefaultPosition, Wx::wxDefaultSize, wxALIGN_RIGHT);
        my $font = Wx::Font->new(10, wxDEFAULT, wxNORMAL, wxNORMAL);
        $text->SetFont($font);
        $buttons_sizer->Add($text, 1, wxEXPAND | wxALIGN_RIGHT);
    }
    
    my $sizer = Wx::BoxSizer->new(wxVERTICAL);
    $sizer->Add($buttons_sizer, 0, wxEXPAND | wxALL, 10);
    $sizer->Add($tabpanel);
    
    $sizer->SetSizeHints($self);
    $self->SetSizer($sizer);
    $self->Layout;
    
    return $self;
}

my $stl_wildcard = "STL files *.stl|*.stl;*.STL";
my $ini_wildcard = "INI files *.ini|*.ini;*.INI";
my $gcode_wildcard = "GCODE files *.gcode|*.gcode;*.GCODE";

sub do_slice {
    my $self = shift;
    my %params = @_;
    
    my $process_dialog;
    eval {
        # validate configuration
        Slic3r::Config->validate;
        
        # select input file
        my $dialog = Wx::FileDialog->new($self, 'Choose a STL file to slice:', $last_dir || "", "", $stl_wildcard, wxFD_OPEN);
        return unless $dialog->ShowModal == wxID_OK;
        my ($input_file) = $dialog->GetPaths;
        my $input_file_basename = basename($input_file);
        $last_dir = dirname($input_file);
        
        my $skein = Slic3r::Skein->new(
            input_file  => $input_file,
            output_file => $main::opt{output},
            status_cb   => sub {
                my ($percent, $message) = @_;
                if (&Wx::wxVERSION_STRING =~ / 2\.(8\.|9\.[2-9])/) {
                    $process_dialog->Update($percent, $message);
                }
            },
        );

        # select output file
        if ($params{save_as}) {
            my $output_file = $skein->expanded_output_filepath;
            my $dlg = Wx::FileDialog->new($self, 'Save gcode file as:', dirname($output_file),
                basename($output_file), $gcode_wildcard, wxFD_SAVE);
            return if $dlg->ShowModal != wxID_OK;
            $skein->output_file($dlg->GetPath);
        }
        
        # show processbar dialog
        $process_dialog = Wx::ProgressDialog->new('Slicing...', "Processing $input_file_basename...", 
            100, $self, wxPD_APP_MODAL);
        $process_dialog->Pulse;
        
        {
            my @warnings = ();
            local $SIG{__WARN__} = sub { push @warnings, $_[0] };
            $skein->go;
            $self->catch_warning->($_) for @warnings;
        }
        $process_dialog->Destroy;
        undef $process_dialog;
        
        if (!$main::opt{close_after_slicing}) {
            my $message = sprintf "%s was successfully sliced in %d minutes and %.3f seconds.",
                $input_file_basename, int($skein->processing_time/60),
                $skein->processing_time - int($skein->processing_time/60)*60;
            Wx::MessageDialog->new($self, $message, 'Done!', 
                wxOK | wxICON_INFORMATION)->ShowModal;
        } else {
            $self->GetParent->Destroy();  # quit
        }
    };
    $self->catch_error(sub { $process_dialog->Destroy if $process_dialog });
}

sub save_config {
    my $self = shift;
    
    my $dir = $last_config ? dirname($last_config) : $last_dir || "";
    my $filename = $last_config ? basename($last_config) : "config.ini";
    my $dlg = Wx::FileDialog->new($self, 'Save configuration as:', $dir, $filename, 
        $ini_wildcard, wxFD_SAVE);
    if ($dlg->ShowModal == wxID_OK) {
        my $file = $dlg->GetPath;
        $last_dir = dirname($file);
        $last_config = $file;
        Slic3r::Config->save($file);
    }
}

sub load_config {
    my $self = shift;
    
    my $dlg = Wx::FileDialog->new($self, 'Select configuration to load:', $last_dir || "", "config.ini", 
        $ini_wildcard, wxFD_OPEN);
    if ($dlg->ShowModal == wxID_OK) {
        my ($file) = $dlg->GetPaths;
        $last_dir = dirname($file);
        $last_config = $file;
        eval {
            local $SIG{__WARN__} = $self->catch_warning;
            Slic3r::Config->load($file);
        };
        $self->catch_error();
        $_->() for @Slic3r::GUI::OptionsGroup::reload_callbacks;
    }
}

sub catch_error {
    my ($self, $cb) = @_;
    if (my $err = $@) {
        $cb->() if $cb;
        Wx::MessageDialog->new($self, $err, 'Error', wxOK | wxICON_ERROR)->ShowModal;
    }
}

sub catch_warning {
    my ($self) = @_;
    return sub {
        my $message = shift;
        Wx::MessageDialog->new($self, $message, 'Warning', wxOK | wxICON_WARNING)->ShowModal;
    };
};

1;
