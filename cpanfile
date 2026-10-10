requires 'perl', '5.020';

requires 'Carp';
requires 'Errno';
requires 'IO::Handle';
requires 'IO::Select';
requires 'Moo';
requires 'namespace::autoclean', '0.16';
requires 'Path::Tiny';
requires 'POSIX';
requires 'Scalar::Util';
requires 'SICK';
requires 'Time::HiRes';
requires 'Type::Tiny';

on test => sub {
  requires 'File::Temp';
  requires 'Test::More', '0.96';
};
