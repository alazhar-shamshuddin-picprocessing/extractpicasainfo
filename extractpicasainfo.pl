#!/usr/bin/perl
################################################################################

=head1 NAME

exctractpicasainfo - extracts Picasa album and contact details to a JSON and/or
                     an SQLite database file

=head1 SYNOPSIS

extractpicasainfo [-?|-h|--help] [-m|--man]
                  [-o|--overwrite]
                  <-d|--dbfile=<extract.db> | -j|--jsonfile=<extract.json>>
                  <root_albums_directory>

extractpicasainfo --help

extractpicasainfo --jsonfile=extract.json ~/pics

extractpicasainfo --jsonfile extract.json --overwrite ~/pics

extractpicasainfo --dbfile extract.db ~/pics

extractpicasainfo -j extract.json -d extract.db -o ~/pics

=head1 OPTIONS

=over 8

=item B<-d, --dbfile=<outfile>>

Outputs the Picasa album information to the specified SQLite database file.

=item B<-j, --jsonfile=<outfile>>

Outputs the Picasa album information to the specified JSON-formatted file.

=item B<-o, --overwrite>

Overwrites the output files, if they exist and are writable, instead of
aborting.

=item B<-?, -h, --help>

Displays a brief help message.

=item B<-m, --man>

Displays a detailed help manual.

=back

=head1 DESCRIPTION

This program extracts information from Picasa photo albums and writes that
information to a JSON file and/or an SQLlite database file.  Specifically,
it iterates through a directory tree rooted at the specified folder, and
treats any folder with a .picasa.ini or a Picasa.ini file (regardless of
capitalization) as a Picasa photo album.  Note that .picasaoriginals folders
are ignored.

The program requires:

   1. The Picasa contacts list which is assumed to be located at
      %USERPROFILE%/AppData/Local/Google/Picasa2/contacts/contacts.xml or
      $USERPROFILE/AppData/Local/Google/Picasa2/contacts/contacts.xml, 
      depending on whether you are running the script from Windows or the
      Windows Subsystem for Linux (WSL).  The script will abort if it cannot
      that file.

      If you're running the script in the WSL, ensure you have a Windows 
      environment variable called "WSLENV" set to "USERPROFILE/p:<othervars>".
      This ensures Windows will share the %USERPROFILE% environment variable
      (along with other variables, if any) with WSL and format the path to be
      compatible (i.e., /mnt/c/Users/... instead of C:/Users/...).

   2. Image files referenced in a picasa.ini file exist in the same folder
      to successfully extract face tag information.  (The program reads
      a referenced image file's EXIF metadata to determine its height and
      width, which in turn are used to determine the coordinates of the
      tagged region.  The face tag region is set to zeros and an error is
      logged if an image file does not exist.)

To view the SQLite database file produced by this program, use the "DB Browser
for SQLite" application available at https://sqlitebrowser.org.

=head1 REVISION HISTORY

Alazhar Shamshuddin   2019-03-04   Version 1.0

=head1 COPYRIGHT

(c) Copyright Alazhar Shamshuddin, 2019, All Rights Reserved.

=cut

################################################################################

use strict;
use warnings;

use feature 'fc';                # For case folding comparisons.

use Data::Dumper;                # For debugging data structures.
use DateTime;                    # For converting decimal numbers to dates.
use DBI;                         # For writing Picasa data to an SQLite DB.
use File::Slurp qw(write_file);  # For writing JSON to file.
use File::Spec;                  # For managing file paths.
use Getopt::Long;                # For command line options processing.
use Image::ExifTool qw(:Public); # For processing EXIF data.
use JSON;                        # For converting Perl data structures to JSON.
use Log::Log4perl;               # For logging.
use Pod::Usage;                  # For printing usage clause and man page.
use POSIX;                       # For math functions like floor.

################################################################################
# Global Variables
################################################################################
use constant TRUE  => 1;
use constant FALSE => 0;

my $gLogger        = undef;
my %gCmds          = ();
my $gJson          = JSON->new;

# Picasa's album dates are represented as the number of days from this date.
# $gDateZero is used to convert that number to an actual date.
# @todo: This should be a constant variable.  Take care to clone this value
#        before using it or your dates may be incorrect.
my $gDateZero = DateTime->new(year  => 1899,
                              month => 12,
                              day   => 30);

################################################################################
# Subroutines
#
#    All subroutines are organized alphanumerically in the following
#    categories:
#
#       - Main
#            - main
#       - Initialization
#            - initLogger
#            - processCmdLineArgs
#       - Data Extraction
#            - decodeFaceTagRectangle
#            - decodeFaceTags
#            - getAlbumCategory
#            - getContactName
#            - processAlbums
#            - processContacts
#            - processIniFile
#            - removeLineEndings
#            - updateContactReferenceCount
#       - Data Preservation
#            - createDb
#            - executeStatement
#            - populateAlbumDescription
#            - populateAlbums
#            - populateContacts
#
################################################################################

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Main
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
main();
sub main
{
   initLogger(0, \$gLogger);
   $gLogger->info("*** Executing $0. ***");

   processCmdLineArgs(\%gCmds);

   my $rootDir = File::Spec->canonpath($gCmds{directory});
   $rootDir = File::Spec->rel2abs($rootDir);

   my %albums       = ();
   my $albumCounter = 1;
   my %contacts     = ();
   my %picasaInfo   = (albums => \%albums, contacts => \%contacts);

   my $contactsDataFile = 'AppData/Local/Google/Picasa2/contacts/contacts.xml';
   $contactsDataFile = File::Spec->catfile($ENV{USERPROFILE}, $contactsDataFile);

   processContacts($contactsDataFile, \%contacts);
   processAlbums($rootDir, \%contacts, \$albumCounter, \%albums);

   # Write data to the JSON output file.
   if (defined($gCmds{jsonfile}))
   {
      my $jsonFile = File::Spec->canonpath($gCmds{jsonfile});
      $jsonFile = File::Spec->rel2abs($jsonFile);

      if (-e $gCmds{jsonfile} && !defined($gCmds{overwrite}))
      {
         $gLogger->logdie("Cannot overwrite the output JSON file " .
                          "'$gCmds{jsonfile}' without the overwrite flag.");
      }

      write_file($jsonFile, $gJson->pretty->encode(\%picasaInfo));
   }

   # Write data to the SQLite database output file.
   if (defined($gCmds{dbfile}))
   {
      my $dbFile = File::Spec->canonpath($gCmds{dbfile});
      $dbFile = File::Spec->rel2abs($dbFile);

      if (-e $gCmds{dbfile})
      {
         if (!defined($gCmds{overwrite}))
         {
            $gLogger->logdie("Cannot overwrite the output SQLite database " .
                             "file '$gCmds{dbfile}' without the overwrite " .
                             "flag.");
         }

         unlink($dbFile) or
            $gLogger->logdie("Could not delete SQLite database file " .
                             "'$dbFile': $!");
      }

      createDb(\%picasaInfo);
   }

   $gLogger->info("*** Completed executing $0. ***");
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Initialization Subroutines
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

#-------------------------------------------------------------------------------
# Initializes the logging functionality.
#
# \param $_[0] [in]  The log configuration filename.
# \param $_[1] [out] A reference to a logger.
#
# \return None.
#-------------------------------------------------------------------------------
sub initLogger
{
   # Initialize the logger.
   my $logConfigFile = $_[0];
   my $logger_sr     = $_[1];

   if (-r $logConfigFile)
   {
      Log::Log4perl->init($logConfigFile);
   }
   else
   {
      # Configuration in a string.
      my $logConfigString = q(
         log4perl.rootLogger=TRACE, FILE, SCREEN

         # Filter to match WARN messages
         #log4perl.filter.MatchInfo = Log::Log4perl::Filter::LevelMatch
         #log4perl.filter.MatchInfo.LevelToMatch = WARN
         #log4perl.filter.MatchInfo.AcceptOnMatch = true

         # Filter to match range from WARN up
         log4perl.filter.MatchWarnUp = Log::Log4perl::Filter::LevelRange
         log4perl.filter.MatchWarnUp.LevelMin = WARN
         #log4perl.filter.MatchWarnUp.LevelMax = FATAL
         log4perl.filter.MatchWarnUp.AcceptOnMatch = true

         #----------------------------------------------------------------------
         # For writing log messages to a file in the following format:
         #
         #   (%r)  (%p)  (%l)                     (%m%n)
         #   [127] ERROR main::fnc file.pl (599): Message.
         #----------------------------------------------------------------------
         log4perl.appender.FILE          = Log::Log4perl::Appender::File
         log4perl.appender.FILE.filename = ./extractpicasainfo.log
         log4perl.appender.FILE.mode     = clobber
         log4perl.appender.FILE.layout   = PatternLayout
         log4perl.appender.FILE.layout.ConversionPattern = %p %l: %m%n

         #----------------------------------------------------------------------
         # For writing log messages to the screen in the following format:
         #
         #   (%r)  (%p)  (%l)                     (%m%n)
         #   [127] ERROR main::fnc file.pl (599): Message.
         #----------------------------------------------------------------------
         log4perl.appender.SCREEN        = Log::Log4perl::Appender::Screen
         log4perl.appender.SCREEN.stderr = 0
         log4perl.appender.SCREEN.layout = PatternLayout
         log4perl.appender.SCREEN.layout.ConversionPattern = %p %l: %m%n
         log4perl.appender.SCREEN.Filter = MatchWarnUp
         );

      Log::Log4perl::init(\$logConfigString);
   }

   $$logger_sr = Log::Log4perl->get_logger("$0");
   die "FATAL: Could not initialize the logger." unless $$logger_sr;
}

#-------------------------------------------------------------------------------
# Processes command line arguments, and informs the user of invalid
# parameters.  All command line options/values are inserted in the global
# commands hash (gCmds).
#
# This subroutine also displays the usage clause if there are any errors,
# or the help or manual pages if the user explicitly requests them.
# Displaying the usage clause, help page, and manual pages via pod2usage
# automatically terminates this script.
#
# \return None.
#-------------------------------------------------------------------------------
sub processCmdLineArgs
{
   Pod::Usage::pod2usage(1) unless
      Getopt::Long::GetOptions(
        "dbfile|d=s"   => \$gCmds{dbfile},
        "jsonfile|j=s" => \$gCmds{jsonfile},
        "overwrite|o"  => \$gCmds{overwrite},
        "help|h|?"     => \$gCmds{help},
        "man|m"        => \$gCmds{man}
      );

   # We expect no remaining commands/options on the command line after we
   # retrieve the directory.  @ARGV should be empty after the following line.
   $gCmds{directory} = shift(@ARGV);

   Pod::Usage::pod2usage(1) if $gCmds{help};
   Pod::Usage::pod2usage(-verbose => 2) if $gCmds{man};

   # Ensure a directory is specified.
   if (!defined($gCmds{directory}))
   {
      my $msg = "A root albums directory (containing Picasa folders) must " .
                "be specified.";

      $gLogger->info($msg);
      print(STDERR "$msg\n\n");
      Pod::Usage::pod2usage(1);
   }

   # Ensure an output file is specified.
   if (!defined($gCmds{jsonfile}) && !defined($gCmds{dbfile}))
   {
      my $msg = "Picasa information must be output to at least one of the " .
                "supported output formats: a JSON file (--jsonfile) or an " .
                "SQLite database file (--dbfile).";

      $gLogger->info($msg);
      print(STDERR "$msg\n\n");
      Pod::Usage::pod2usage(1);
   }

   # Ensure the overwrite switch is specified if the JSON output file exists.
   if (defined($gCmds{jsonfile}) &&
       -e $gCmds{jsonfile} &&
       !defined($gCmds{overwrite}))
   {
      my $msg = "The JSON output file '$gCmds{jsonfile}' exists.  Consider " .
                "using the --overwrite switch.";

      $gLogger->info($msg);
      print(STDERR "$msg\n\n");
      Pod::Usage::pod2usage(1);
   }

   # Ensure the overwrite switch is specified if the SQLite database output
   # file exists.
   if (defined($gCmds{dbfile}) &&
       -e $gCmds{dbfile} &&
       !defined($gCmds{overwrite}))
   {
      my $msg = "The SQLite database output file '$gCmds{dbfile}' exists.  " .
                "Consider using the --overwrite switch.";

      $gLogger->info($msg);
      print(STDERR "$msg\n\n");
      Pod::Usage::pod2usage(1);
   }

   # Ensure the multiple output files are not the same.
   if (defined($gCmds{jsonfile}) &&
       defined($gCmds{dbfile}) &&
       fc($gCmds{jsonfile}) eq fc($gCmds{dbfile}))
   {
      my $msg = "The JSON output file '$gCmds{jsonfile}' cannot be the same " .
                "as the SQLite database output file '$gCmds{dbfile}'.";

      $gLogger->info($msg);
      print(STDERR "$msg\n\n");
      Pod::Usage::pod2usage(1);
   }

   # Ensure there are no more command line parameters to process.  Currently
   # we do not allow the user to process more than one directory at a time.
   if (scalar(@ARGV) > 0)
   {
      my $dirs = join(',', @ARGV);
      my $msg = "Invalid command line entries: '$dirs'.  $0 can only " .
                "process one root directory at a time.";

      $gLogger->info($msg);
      print(STDERR "$msg\n\n");
      Pod::Usage::pod2usage(1);
   }
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Data Extraction Subroutines
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

#-------------------------------------------------------------------------------
# Decodes Picasa's 64-bit hexadecimal encoding of a face tag rectangle
# (e.g., aa95109fb609ca34) into a human-readable reference to a hash like
# the following:
#
#    {
#       'xCoord' => 0,
#       'yCoord' => 3275,
#       'width' => 756,
#       'height' => 757
#    },
#
# If Picasa's encoding is not 64-bit, we padded with 0s such that
#
#    bc5c31f2b04bb94
#
# would become
#
#    0bc5c31f2b04bb94
#
# \param $_[0] [in] A string representing the encoded face tag coordinates.
# \param $_[1] [in] The width of the image containing the specified face tags.
# \param $_[2] [in] The height of the image containing the specified face tags.
#
# \return A reference to a hash described above.
#-------------------------------------------------------------------------------
sub decodeFaceTagRectangle
{
   my $rect64      = $_[0];
   my $imageWidth  = $_[1];
   my $imageHeight = $_[2];

   # Pad the 64-bit encoded face tag coordinates with preceding zeros to ensure
   # it contains 16 characters.
   $rect64 = sprintf("%016s", $rect64);

   my $left   = floor((hex(substr($rect64,  0, 4)) * $imageWidth)  / 65535);
   my $top    = floor((hex(substr($rect64,  4, 4)) * $imageHeight) / 65535);
   my $right  = floor((hex(substr($rect64,  8, 4)) * $imageWidth)  / 65535);
   my $bottom = floor((hex(substr($rect64, 12, 4)) * $imageHeight) / 65535);

   my %faceCoords = (xCoord => $left,
                     yCoord => $top,
                     width  => $right - $left,
                     height => $bottom - $top);

   return \%faceCoords;
}

#-------------------------------------------------------------------------------
# Decodes Picasa's face tag information associated with an image.
#
# Picasa stores all the faces tagged in an image as a semi-colon delimited
# string.  The following examples comes from an image in which two faces
# were tagged.
#
#    'rect64(4f5c2b4e8c518ccc),aa95109fb609ca34;rect64(6b8399959ebbeb8),9928f1dc983ded75'
#
# In order to determine the rectangular region of each face tag, the image
# file must be readable.  This function extracts the image's width and height
# from its EXIF metadata.  Without it, it will log an error message and return
# an invalid tagged region shown below:
#
#    { xCoord => 0, yCoord => 0, width => 0, height => 0 }
#
# In order to determine the name of the person associated with each face tag,
# this function relies on a global hash of all Picasa contacts as shown below:
#
#    { 'Alazhar Shamshuddin' =>  { 'aa95109fb609ca34' => { 'count' : 0 } },
#      'Maxwell Vincent'     =>  { '9928f1dc983ded75' => { 'count' : 0 } }
#    }
#
# If all goes well, this function will return a reference to hash containing
# the decoded face tag information like the example shown below:
#
#    {
#       'Alazhar Shamshuddin' => {
#         'xCoord' => 1104,
#         'yCoord' => 3275,
#         'width' => 757,
#         'height' => 757
#       },   
#       'Maxwell Vincent' => {
#          'xCoord' => 0,
#          'yCoord' => 3275,
#          'width' => 756,
#          'height' => 757
#       }
#    }
#
# It will also increment the count (depicting the number of pictures each
# contact is in) in the global Picasa contact hash and the local contact
# hash for the album.
#
# \param $_[0] [in]     A string representing one or more encoded face tags.
# \param $_[1] [in]     The absolute path to the image file containing the
#                       encoded face tags.
# \param $_[2] [in-out] A reference to a hash of contacts for the album keyed
#                       on the contact's name.
# \param $_[3] [in-out] A reference to a hash of all Picasa contacts keyed on
#                       the contact's name.
#
# \return A reference to a hash of face tags as described above.
#-------------------------------------------------------------------------------
sub decodeFaceTags
{
   my $encodedFaceTags_string = $_[0];
   my $imageFile              = $_[1];
   my $albumContacts_hr       = $_[2];
   my $picasaContacts_hr      = $_[3];

   my @encodedFaceTags = split(';', $encodedFaceTags_string);
   my %faceTags = ();

   my $exifTool = new Image::ExifTool;
   my $imageInfo = ImageInfo($imageFile, 'ImageWidth', 'ImageHeight');

   # Log an error message and assume an image width and height of zero if the
   # image file cannot be read.
   if (!%$imageInfo)
   {
      $gLogger->error("$imageFile does not exist; cannot extract face tags.");

      $imageInfo->{ImageWidth} = 0;
      $imageInfo->{ImageHeight} = 0;
   }

   foreach my $encodedFaceTag (@encodedFaceTags)
   {
      if ($encodedFaceTag =~ m!rect64\(([0-9A-F]+)\),([0-9A-F]{12,16})$!i)
      {
         my $encodedTagCoordinates = $1;
         my $contactId = $2;

         if ($contactId eq 'ffffffffffffffff')
         {
            # Ignore these invalid contacts.
            next;
         }
         else
         {
            my $contactName = getContactName($contactId, $picasaContacts_hr);

            if ($contactName)
            {
               $faceTags{$contactName} =
                  decodeFaceTagRectangle($encodedTagCoordinates,
                                         $imageInfo->{ImageWidth},
                                         $imageInfo->{ImageHeight});

               updateContactReferenceCount(
                  $contactName, $contactId, $picasaContacts_hr);

               updateContactReferenceCount(
                  $contactName, $contactId, $albumContacts_hr);
            }
            else
            {
               $gLogger->error("Cannot find '$contactId' in the album " .
                               "contacts or the global Picasa contact list " .
                               "for image '$imageFile'.");
            }
         }
      }
      else
      {
         $gLogger->logdie("Invalid encoded face tag '$encodedFaceTag'.");
      }
   }

   return \%faceTags;
}

#-------------------------------------------------------------------------------
# Get an album category associated with the specified album name.
#
# This method attempts to help us categorize albums in a future photo
# management systems.  To that end, it is crude -- we determine a suitable
# category based on the first word in our album's name.
#
# Our albums must map to one of the following categories:
#    - Biking
#    - Camping
#    - Celebrating
#    - Enjoying
#    - Exploring
#    - Hiking
#    - Kayaking
#    - Living
#    - Snowboarding
#    - Working
#    - Unknown
#
# \param $_[0] [in] The album name formatted as 'YYYY_MM_DD - Album Title'.
#
# \return The category associated with this album.
#-------------------------------------------------------------------------------
sub getAlbumCategory
{
   my $albumName = $_[0];

   my %categoryMap = (Biking       => 'Biking',
                      Hiking       => 'Hiking',
                      Snowshoeing  => 'Hiking',
                      Walking      => 'Hiking',
                      Camping      => 'Camping',
                      Caving       => 'Camping',
                      Winter       => 'Camping',
                      Climbing     => 'Climbing',
                      Learning     => 'Climbing',
                      Kayaking     => 'Kayaking',
                      Snowboarding => 'Snowboarding',
                      Celebrating  => 'Celebrating',
                      Flying       => 'Celebrating',
                      Graduating   => 'Celebrating',
                      Jumping      => 'Celebrating',
                      Exploring    => 'Exploring',
                      Visiting     => 'Exploring',
                      Burying      => 'Living',
                      Fighting     => 'Living',
                      Recovering   => 'Living',
                      Styling      => 'Living',
                      Enjoying     => 'Enjoying',
                      BBQing       => 'Enjoying',
                      Bungee       => 'Enjoying',
                      Dining       => 'Enjoying',
                      Eating       => 'Enjoying',
                      Golfing      => 'Enjoying',
                      Paddle       => 'Enjoying',
                      Paragliding  => 'Enjoying',
                      Playing      => 'Enjoying',
                      Runing       => 'Enjoying',
                      Go           => 'Working',
                      Leaving      => 'Working',
                      Working      => 'Working');

   my $category = undef;

   if ($albumName =~ m!\d{4}_\d{2}_\d{2} - (\w+).*!)
   {
      my $firstWord = $1;

      if ($categoryMap{$firstWord})
      {
         $category = $categoryMap{$firstWord};
      }
      else
      {
         $category = 'Unknown';
         $gLogger->warn("Unable to determine a category for album ".
                        "'$albumName' where the first word is '$firstWord'.");
      }
   }
   else
   {
      $category = 'Unknown';
      $gLogger->warn("Unable to determine a category for album '$albumName' " .
                     "Album does not match formatting rules.");
   }

   return $category;
}

#-------------------------------------------------------------------------------
# Gets the name of the Picasa contact that is associated with the specified ID
# in Picasa's global contacts list or undef if a contact cannot be found.
#
# \param $_[0] [in] A contact's Picasa ID.
# \param $_[1] [in] A reference to a hash of all Picasa contacts keyed on the
#                   contact's name.
#
# \return The contact name associated with the specified Picasa ID or undef.
#-------------------------------------------------------------------------------
sub getContactName
{
   my $contactId   = $_[0];
   my $contacts_hr = $_[1];

   foreach my $name (keys(%$contacts_hr))
   {
      foreach my $picasaId (keys(%{$contacts_hr->{$name}}))
      {
         if ($contactId eq $picasaId)
         {
            return $name;
         }
      }
   }

   return undef;
}

#-------------------------------------------------------------------------------
# Processes the specified directory and all its subdirectories.  Any directory
# that contains a .picasa.ini or a Picasa.ini file (regardless of
# capitalization) is assumed to be Picasa album (from which we will attempt
# to extract the relevant album and photo details).  Because .picasaoriginals
# folders are Picasa's backup folders, they are ignored even if they contain a
# picasa.ini file.
#
# Note that this is a recursive function that calls itself for each
# subdirectory in the specified root folder, and builds up an albums hash
# like the following:
#
#    {
#       '1' => {
#          'date'        => '20190105',
#          'name'        => '2019_01_05 - Dining with Maxwell Vincent',
#          'location'    => 'Port Moody, BC, Canada',
#          'description' => 'This was another wonderful (vegetarian)...',
#          'directory'   => '/cygdrive/d/Alazhar/Development/project...',
#          'category'    => 'Enjoying'
#          'contacts'    => {
#             'Alazhar Shamshuddin' => { 'aa95109fb609ca34' => { 'count' : 15 } },
#             'Muffadal Shamshuddin' => { '8b98217573da0b24' => { 'count' : 15 } },
#          },
#          'files' => {
#             'Maxwell_Dinner_0003.jpg' => {
#                'tags' => { 'starred' => 1 }
#             },
#             'Maxwell_Dinner_0004.jpg' => {
#                'facetags' => {
#                   'Muffadal Shamshuddin' => {
#                      'xCoord' => 0,
#                      'yCoord' => 3275,
#                      'width' => 756,
#                      'height' => 757
#                   },
#                   'Alazhar Shamshuddin' => {
#                     'xCoord' => 1104,
#                     'yCoord' => 3275,
#                     'width' => 757,
#                     'height' => 757
#                   }
#                },
#                'tags' => { 'hidden' => 1, 'starred' => 1 }
#             }
#          }
#       }
#       '2' => { ... },
#       ...
#    }
#
# \param $_[0] [in]     The absolute path of the directory to be processed.
# \param $_[1] [in_out] A reference to a hash of Picasa contacts keyed on the
#                       person's name.
# \param $_[2] [in_out] A reference to number representing the number of albums
#                       processed.
# \param $_[3] [in_out] A reference to a hash of Picasa albums keyed on the
#                       album counter.
#
# \return None.
#-------------------------------------------------------------------------------
sub processAlbums
{
   my $rootDir         = $_[0];
   my $contacts_hr     = $_[1];
   my $albumCounter_hr = $_[2];
   my $albums_hr       = $_[3];

   opendir(my $rootDir_fh, $rootDir) or
      $gLogger->logdie("Cannot opendir '$rootDir': $!");

   $gLogger->info("Processing '$rootDir'.");

   # Recursively process each directory and file in the root folder.
   foreach my $item (sort readdir($rootDir_fh))
   {
      # Rename $item to include absolute path information.
      my $itemWithPath = File::Spec->catfile($rootDir, $item);
      $itemWithPath = File::Spec->canonpath($itemWithPath);

      if (-f $itemWithPath)
      {
         if ($item =~ m!^\.?picasa\.ini$!i)
         {
            # We found a picasa.ini file!  Process this file/directory as a
            # Picasa album.
            my %album = ();
            processIniFile($itemWithPath, $contacts_hr, \%album);

            if (defined($albums_hr->{$$albumCounter_hr}))
            {
               $gLogger->logdie("An album with key '$$albumCounter_hr' " .
                                "already exists.");
            }

            $albums_hr->{$$albumCounter_hr} = \%album;
            $$albumCounter_hr++;
         }
      }
      elsif (-d $itemWithPath)
      {
         if (($itemWithPath =~ m!\.{2}$!) ||
             ($itemWithPath eq $rootDir) ||
             ($itemWithPath =~ m!\.picasaoriginals$!))
         {
            # Ignore the current, parent and .picasaoriginals directories.
            next;
         }

         # Recursively process subdirectories.
         processAlbums($itemWithPath,
                       $contacts_hr,
                       $albumCounter_hr,
                       $albums_hr);
      }
      else
      {
         $gLogger->logdie("Cannot process '$itemWithPath' as a file or a " .
                          "directory.");
      }

   }

   closedir($rootDir_fh);
}

#-------------------------------------------------------------------------------
# Processes the global list of Picasa contacts and creates a reference directory
# like the one shown below.  The hexadecimal values are Picasa IDs for each
# contact.  The counts represent the number of photos in which the specified
# Picasa ID was tagged.  (It is possible that a particular person may be
# associated with multiple Picasa IDs.)
#
#    {
#       'Alazhar Shamshuddin' => { 'aa95109fb609ca34' => { 'count' : 11 },
#                                  'f4f5e35256dbc1eb' => { 'count' : 5 },
#                                  '276aee08d8930bed' => { 'count' : 5 }
#                                },
#       'Jane Doe'            => { 'a314094943e17aed' => { 'count' : 0 }
#                                }
#    }
#
# \param $_[0] [in]  The absolute path to the Picasa contacts file.
# \param $_[1] [out] A reference to a hash of contacts described above.
#
# \return None.
#-------------------------------------------------------------------------------
sub processContacts
{
   my $contactsFile = $_[0];
   my $contacts_hr  = $_[1];

   # Reset the contacts hash because it is an out variable.
   %$contacts_hr = ();

   open(my $contactsFile_fh, '<', $contactsFile) or
      $gLogger->logdie("Cannot open '$contactsFile': $!");

   while (<$contactsFile_fh>)
   {
      my $line = removeLineEndings($_);

      if ($line =~ m!id="([a-f0-9]+)" name="(.+?)"!)
      {
         my $name = $2;
         my $id = $1;

         if ($contacts_hr->{$name})
         {
            $gLogger->info(
               "The contact '$name' already exists in Picasa with another " .
               "ID'.  The contact record with ID '$id' will still be " .
               "processed.");
         }

         $contacts_hr->{$name}->{$id}->{'count'} =  0;
      }
      else
      {
         next;
      }
   }

   close($contactsFile_fh)
}

#-------------------------------------------------------------------------------
# Processes the specified picasa.ini file (and related images in the same
# directory) and extracts the relevant details in an output hash like the
# following:
#
#    {
#       'date'        => '20190105',
#       'name'        => '2019_01_05 - Dining with Maxwell Vincent',
#       'location'    => 'Port Moody, BC, Canada',
#       'description' => 'This was another wonderful (vegetarian)...',
#       'directory'   => '/cygdrive/d/Alazhar/Development/project...',
#       'category'    => 'Enjoying'
#       'contacts'    => {
#          'Alazhar Shamshuddin' => { 'aa95109fb609ca34' => { 'count' : 15 } },
#          'Muffadal Shamshuddin' => { '8b98217573da0b24' => { 'count' : 15 } },
#       },
#       'files' => {
#          'Maxwell_Dinner_0003.jpg' => {
#             'tags' => { 'starred' => 1 }
#          },
#          'Maxwell_Dinner_0004.jpg' => {
#             'facetags' => {
#                'Muffadal Shamshuddin' => {
#                   'xCoord' => 0,
#                   'yCoord' => 3275,
#                   'width' => 756,
#                   'height' => 757
#                },
#                'Alazhar Shamshuddin' => {
#                  'xCoord' => 1104,
#                  'yCoord' => 3275,
#                  'width' => 757,
#                  'height' => 757
#                }
#             },
#             'tags' => { 'hidden' => 1, 'starred' => 1 }
#          }
#       }
#    }
#
# \param $_[0] [in]     The absolute path to the album's picasa.ini file.
# \param $_[1] [in_out] A reference to a hash that contains Picasa contacts
#                       for all albums (not just his album).
# \param $_[2] [out]    A reference to a hash that will contain the details of
#                       this particular INI file or photo album as described
#                       above.
#
# \return None.
#-------------------------------------------------------------------------------
sub processIniFile
{
   my $iniFile     = $_[0];
   my $contacts_hr = $_[1];
   my $album_hr    = $_[2];

   # Reset the album hash because it is an out variable.
   %$album_hr = ();

   # A contacts hash to track contacts referenced in this album.
   my %contacts = ();

   # Get the absolute path to the album directory (which is the folder in
   # which the picasa.ini file lives).
   my ($albumVolume, $albumDir, $tmpFile) = File::Spec->splitpath($iniFile);

   # Process the INI file for everything else other than contacts.
   open(my $iniFile_fh, '<', $iniFile) or
      $gLogger->logdie("Cannot open '$iniFile': $!");

   my $section = undef;

   while (<$iniFile_fh>)
   {
      my $line = removeLineEndings($_);

      if($line =~ m!^\[(.*)\]$!)
      {
         $section = $1;
         next;
      }

      if ($section eq 'Picasa')
      {
         if ($line =~ m!^name=(.*)$!)
         {
            $album_hr->{name} = $1;
            $album_hr->{category} = getAlbumCategory($1);
            $album_hr->{directory} = $albumDir;
            $album_hr->{contacts} = \%contacts;
         }
         elsif ($line =~ m!^date=(.*)$!)
         {
            $album_hr->{date} =
               $gDateZero->clone->add( days => $1 )->strftime('%Y-%m-%d');
         }
         elsif ($line =~ m!^location=(.*)$!)
         {
            $album_hr->{location} = $1;
         }
         elsif ($line =~ m!^description=(.*)$!)
         {
            $album_hr->{description} = $1;
         }
      }
      elsif ($section =~ m!([A-Z].+_\d{4}\.[a-z|4]{3})!)
      {
         my $file = $1;

         if ($line =~ m!^faces=(.*)$!)
         {
            my $encodedFaceTags = $1;

            my $imageFile = File::Spec->catfile($albumDir, $file);;

            $album_hr->{files}->{$file}->{facetags} =
               decodeFaceTags($encodedFaceTags,
                              $imageFile,
                              $album_hr->{contacts},
                              $contacts_hr);
         }
         elsif ($line =~ m!^hidden=yes$!)
         {
            $album_hr->{files}->{$file}->{tags}->{hidden} = TRUE;
         }
         elsif ($line =~ m!^star=yes$!)
         {
            $album_hr->{files}->{$file}->{tags}->{starred} = TRUE;
         }
         elsif ($line =~ m!^BKTag .+$! ||
                $line =~ m!^backuphash=\d+$! ||
                $line =~ m!^crop=.+$! ||
                $line =~ m!^filters=.+$! ||
                $line =~ m!^IIDLIST_alazhar\.shamshuddin_lh=[a-z0-9]+$! ||
                $line =~ m!^moddate=.+$! ||
                $line =~ m!^onlinechecksum=.+$! ||
                $line =~ m!^originhash=.+$! ||
                $line =~ m!^redo=.+$! ||
                $line =~ m!^rotate=.+$! ||
                $line =~ m!^textactive=.+$!)
         {
            # Ignore these attributes associated with a file:
            #    - BKTag.  Not sure what this refers to but it's not used in
            #      later versions of Picasa.
            #    - backuphash likely refers to the original file in the
            #      .picasaoriginals folder that we don't care about.
            #    - IIDLIST_* identifies the Google account with which this
            #      album was uploaded to Picasa Web.
            #    - redo, rotate, and moddate probably identify how and when the
            #      original file was changed.
            next;
         }
         else
         {
            $gLogger->warn("Unrecognized line '$line' in section '$section' " .
                           "of the picasa.ini file.");
         }
      }
      elsif ($section eq 'Contacts2' ||
             $section eq 'encoding' ||
             $section eq 'photoid' ||
             #$section =~ m![a-z]+-[0-9]+\.[a-z]{3}!i ||
             #$section =~ m![a-z]+\.wmv!i ||
             #$section =~ m!IMG_[0-9]{4}\.[jgp|JPG]! ||
             #$section =~ m!DSC\d+\.[jgp|JPG]! ||
             #$section =~ m!P\d+\.[jgp|JPG]! ||
             #$section =~ m!STC_[0-9]{4}\.[jgp|JPG]! ||
             $section =~ m!\.album:[A-F0-9]+!i)
      {
         # Ignore these sections.  We don't care about:
         #    - The contacts2 section of a picasa.ini file is not accurate --
         #      it contains duplicate entries and references to old contact
         #      names that have since been changed.
         #    - The text encoding. It's not used in later versions Picasa.
         #    - Sections associated with files named like 'x-008.jpg' or
         #      'foo.wmv" as they are remnants of old file names before the
         #      folder/album was finalized with the proper naming conventions.
         #    - .album sections.  We don't know if Picasa uses these sections
         #      but they are unlikely to contain any information we want.
         next;
      }
      elsif ($section =~ m!([a-z].+\.[a-z]{3})!i)
      {
         my $tmpFile = File::Spec->catfile($albumDir, $section);

         if (-e $tmpFile)
         {
            $gLogger->error("Picasa references a file ('$tmpFile') that " .
                            "does not follow naming conventions.  It " .
                            "will be ignored.");
         }
         else
         {
            # This file does not exist; we assume the picasa.ini file is
            # referencing it in error as it often does (after files are
            # renamed).
            next;
         }
      }
      else
      {
         $gLogger->warn("Unknown section '$section' in '$iniFile'.");
      }
   }

   close($iniFile_fh);
}

#-------------------------------------------------------------------------------
# Removes Windows and Unix line endings (\r\n or \n), if any, from the
# specified string.
#
# \param $_[0] [in] The string to be processed.
#
# \return The string that was passed in without any line endings.
#-------------------------------------------------------------------------------
sub removeLineEndings
{
   my $line = $_[0];

   $line =~ s!\r?\n$!!;

   return $line;
}

#-------------------------------------------------------------------------------
# Increment the number of photos in which the specified contact with the
# specified Picasa ID was tagged.
#
# \param $_[0] [in]     The name of the contact (or tagged person).
# \param $_[1] [in]     The Picasa ID associated with the contact.
# \param $_[2] [in-out] A reference to a global list of Picasa contacts keyed
#                       on the contact name.
#
# \return None.
#-------------------------------------------------------------------------------
sub updateContactReferenceCount
{
   my $name        = $_[0];
   my $id          = $_[1];
   my $contacts_hr = $_[2];

   if ($contacts_hr->{$name})
   {
      if ($contacts_hr->{$name}->{$id})
      {
         # Increment the reference count.
         $contacts_hr->{$name}->{$id}->{count}++;
      }
      else
      {
         my $existingIds = join(', ', keys(%{$contacts_hr->{$name}}));

         $gLogger->info(
               "The contact '$name' already exists in Picasa with ID(s) " .
               "'$existingIds'.  Adding contact record with ID '$id' and " .
               "continuing processing.");

         $contacts_hr->{$name}->{$id}->{count} = 1;
      }

   }
   else
   {
      $gLogger->info(
            "The contact '$name' does not exist in the Picasa contacts " .
            "file.  Adding contact record with ID '$id' and continuing " .
            "processing.");

      $contacts_hr->{$name}->{$id}->{count} = 1;
   }
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Data Preservation Subroutines
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

#-------------------------------------------------------------------------------
# Creates the SQLite database and populates it with the information extracted
# from Picasa.
#
# \param $_[0] [in] A reference to the hash containing the extracted Picasa
#                   information.
#
# \return None.
#-------------------------------------------------------------------------------
sub createDb
{
   my $picasaInfo_hr = $_[0];

   my $driver   = "SQLite";
   my $database = $gCmds{dbfile};
   my $dsn      = "DBI:$driver:dbname=$database";
   my $userid   = "";
   my $password = "";
   my $dbh = DBI->connect($dsn,
                          $userid,
                          $password,
                          { RaiseError => 1, AutoCommit => 0 })
      or $gLogger->logdie("Could not create the database: $DBI::errstr.");

   my @schemaDefs = (
      qq(CREATE TABLE Contacts
            (name           TEXT    NOT NULL,
             picasaId       TEXT    NOT NULL,
             referenceCount INT     NOT NULL,
             PRIMARY KEY (name, picasaId));),

      qq(CREATE TABLE Albums
            (id             INTEGER PRIMARY KEY,
             name           TEXT    NOT NULL,
             date           DATE    NOT NULL,
             location       TEXT,
             description    TEXT,
             category       TEXT,
             path           TEXT    NOT NULL,
             UNIQUE(name),
             UNIQUE(path));),

      qq(CREATE TABLE FaceTags
            (albumName      TEXT    NOT NULL,
             imageFile      TEXT    NOT NULL,
             person         TEXT    NOT NULL,
             xCoord         INT     NOT NULL,
             yCoord         INT     NOT NULL,
             width          INT     NOT NULL,
             height         INT     NOT NULL,
             PRIMARY KEY (albumName,
                          imageFile,
                          person,
                          xCoord,
                          yCoord,
                          width,
                          height));),

      qq(CREATE TABLE Tags
            (albumName      TEXT    NOT NULL,
             imageFile      TEXT    NOT NULL,
             starred        BOOLEAN NOT NULL,
             hidden         BOOLEAN NOT NULL,
             PRIMARY KEY (albumName,
                          imageFile));),

      qq(CREATE VIEW ContactCounts AS
            SELECT  name
                   ,count(*) as numPicasaIds
                   ,sum(referenceCount) as numPhotoReferences
            FROM Contacts
            GROUP BY name)
      );

   foreach my $stmt (@schemaDefs)
   {
      executeStatement($dbh, $stmt);
   }

   populateContacts($dbh, $picasaInfo_hr->{contacts});
   populateAlbums($dbh, $picasaInfo_hr->{albums});

   $dbh->commit();
   $dbh->disconnect();
}

#-------------------------------------------------------------------------------
# Executes the specified SQL statement against the specified database.
#
# \param $_[1] [in] The database handle.
# \param $_[1] [in] The SQL statement to execute.
#
# \return None.
#-------------------------------------------------------------------------------
sub executeStatement
{
   my $dbh  = $_[0];
   my $stmt = $_[1];

   my $rv = $dbh->do($stmt);

   if($rv < 0)
   {
      $gLogger->logdie("Could not create table: $DBI::errstr");
   }
}

#-------------------------------------------------------------------------------
# Populates the album description from the specified album.
#
# This function works around SQLite's shortcoming: it doesn't support new line
# characters (or other escaped white space annotations) in strings.  This
# method, however kludgey, is the only way we know how to preserve new line
# characters in our album descriptions.
#
# \param $_[1] [in] The database handle.
# \param $_[1] [in] The album ID or key whose description we want to populate.
# \param $_[2] [in] The album's description.
#
# \return None.
#-------------------------------------------------------------------------------
sub populateAlbumDescription
{
   my $dbh         = $_[0];
   my $albumKey    = $_[1];
   my $description = $_[2];

   if (!$description)
   {
      # Don't do anything if the description is an empty string or null.
      return;
   }

   my $stmt = qq(UPDATE Albums
                 SET description = ''
                 WHERE id = "$albumKey");

   executeStatement($dbh, $stmt);

   $description =~ s!"!'!g;

   # Split the description into individual lines.
   my @lines = split(/\\n/, $description);

   # Process each line.
   for (my $i = 0; $i < scalar(@lines); $i++)
   {
      my $stmt = '';

      if ($i != $#lines )
      {
         # If this is not the last line in description, add a new line
         # character (char(10)) to the end of the description.
         $stmt = qq(UPDATE Albums
                    SET    description = description || "$lines[$i]" || char(10)
                    WHERE  id = "$albumKey");
      }
      else
      {
         # If this is the last line in description, do not add a new line
         # character (char(10)) to the end of the description.
        $stmt = qq(UPDATE Albums
                   SET    description = description || "$lines[$i]"
                   WHERE  id = "$albumKey");
      }

      executeStatement($dbh, $stmt);
   }
}

#-------------------------------------------------------------------------------
# Populates the database with album-related information extracted from Picasa.
#
# \param $_[1] [in] The database handle.
# \param $_[1] [in] A reference to a hash of extracted Picasa albums.
#
# \return None.
#-------------------------------------------------------------------------------
sub populateAlbums
{
   my $dbh       = $_[0];
   my $albums_hr = $_[1];

   my $sth_albums =
      $dbh->prepare("INSERT INTO Albums
                         (id, name, date, location, description, category, path)
                       VALUES (?, ?, ?, ?, ?, ?, ?)");

   my $sth_faceTags =
      $dbh->prepare("INSERT INTO FaceTags
                        (albumName,
                         imageFile,
                         person,
                         xCoord,
                         yCoord,
                         width,
                         height)
                     VALUES (?, ?, ?, ?, ?, ?, ?)");

   my $sth_otherTags =
      $dbh->prepare("INSERT INTO Tags
                        (albumName, imageFile, starred, hidden)
                     VALUES (? ,?, ?, ?)");

   foreach my $albumKey (sort(keys(%$albums_hr)))
   {
      $sth_albums->execute($albumKey,
                           $albums_hr->{$albumKey}->{name},
                           $albums_hr->{$albumKey}->{date},
                           $albums_hr->{$albumKey}->{location},
                           undef,
                           $albums_hr->{$albumKey}->{category},
                           $albums_hr->{$albumKey}->{directory});

      populateAlbumDescription($dbh,
                               $albumKey,
                               $albums_hr->{$albumKey}->{description});

      my $files_hr = $albums_hr->{$albumKey}->{files};

      foreach my $file (sort(keys(%$files_hr)))
      {
         foreach my $person (sort(keys(%{$files_hr->{$file}->{facetags}})))
         {
            $sth_faceTags->execute(
               $albums_hr->{$albumKey}->{name},
               $file,
               $person,
               $files_hr->{$file}->{facetags}->{$person}->{xCoord},
               $files_hr->{$file}->{facetags}->{$person}->{yCoord},
               $files_hr->{$file}->{facetags}->{$person}->{height},
               $files_hr->{$file}->{facetags}->{$person}->{width});
         }

         if (defined($files_hr->{$file}->{tags}))
         {
            $sth_otherTags->execute(
               $albums_hr->{$albumKey}->{name},
               $file,
               defined($files_hr->{$file}->{tags}->{starred}) ? $files_hr->{$file}->{tags}->{starred} : 0,
               defined($files_hr->{$file}->{tags}->{hidden}) ? $files_hr->{$file}->{tags}->{hidden} : 0);
         }
      }
   }
}

#-------------------------------------------------------------------------------
# Populates the database with contact-related information extracted from Picasa.
#
# \param $_[1] [in] The database handle.
# \param $_[1] [in] A reference to a hash of extracted Picasa contacts.
#
# \return None.
#-------------------------------------------------------------------------------
sub populateContacts
{
   my $dbh         = $_[0];
   my $contacts_hr = $_[1];

   my $sth = $dbh->prepare("INSERT INTO Contacts
                              (name, picasaId, referenceCount)
                            VALUES (?, ?, ?)");

   foreach my $contact (sort(keys(%$contacts_hr)))
   {
      foreach my $picasaId (sort(keys(%{$contacts_hr->{$contact}})))
      {
         $sth->execute($contact,
                       $picasaId,
                       $contacts_hr->{$contact}->{$picasaId}->{count});
      }
   }
}
