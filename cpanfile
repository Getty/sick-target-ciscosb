requires 'perl', '5.020';

requires 'Carp';
requires 'Errno';
requires 'IO::Handle';
requires 'IO::Select';
requires 'POSIX';
requires 'Scalar::Util';
requires 'SICK';
requires 'Time::HiRes';

on test => sub {
  requires 'File::Temp';
  requires 'Test::More', '0.96';
};
