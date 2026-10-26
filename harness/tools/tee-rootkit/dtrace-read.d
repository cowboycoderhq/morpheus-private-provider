/* Counts read() calls of $1 and tries to copy the first bytes of each buffer. */
syscall::read:entry, syscall::read_nocancel:entry /pid == $1/ { self->buf = arg1; }
syscall::read:return, syscall::read_nocancel:return /pid == $1 && self->buf && arg0 > 0/
{ printf("COPY %d %s\n", arg0, copyinstr(self->buf, 24)); self->buf = 0; }
