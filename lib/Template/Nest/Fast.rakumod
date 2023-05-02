#| Template::Nest::Fast is a high-performance template engine module
#| for Raku, designed to process nested templates quickly and
#| efficiently. This module improves on the original Template::Nest
#| module by caching the index of positions of variables, resulting in
#| significantly faster processing times.
class Template::Nest::Fast {
    has Str @.token-delims = ['<!--%', '%-->'];
    has Str $.name-label = 'TEMPLATE';
    has IO $.template-dir is required;
    has Str $.template-extension = 'html';

    # If True, add comment to the rendered output to make it easier to
    # identify which template the output is from.
    has Bool $.show-labels = False;

    # Used in conjuction with $.show-labels. If the template is not
    # HTML then this can be used to change output label.
    has Str @.comment-delims = ['<!--', '-->'];

    # If True, then an attempt to populate a template with a variable
    # that doesn't exist (i.e. name not found in template) results in
    # an error.
    has Bool $.die-on-bad-params = False;

    # Intended to improve readability when inspecting nested
    # templates.
    has Bool $.fixed-indent = False;

    # To escape token delimiters.
    has Str $.token-escape-char = '';

    has %.defaults;
    has $.defaults-namespace-char = '.';

    # If True, then cache the template file in memory.
    has $.cache-template = True;

    # Template objects after compilation.
    has %!templates;

    #| TWEAK reads all the files in template-dir ending with '.html'
    #| extension and indexes them.
    submethod TWEAK() {
        # Grab all files ending with $!template-extension recursively.
        # If the extension is set to an empty string, grab all the
        # files.
        my IO @stack = $!template-dir, ;
        my IO @templates = gather while @stack {
            with @stack.pop {
                when :d { @stack.append: .dir }
                when $!template-extension eq '' { .take }
                when .extension.lc eq $!template-extension { .take }
            }
        }

        # Render all the files.
        self!index-template($_) for @templates;
    }

    #| index-template reads a template and prepares it for render.
    method !index-template(IO $template) {
        # Get template name relative to $!template-dir and remove
        # extension. Remove the extension and the dot. If
        # $!template-extension is empty then there is no extension
        # length.
        my Int $extension-length =  $_ eq '' ?? 0 !! (.chars + 1) with $!template-extension;
        my Str $t = $template.relative($!template-dir).substr(0, *-$extension-length);
        my Str $f = $template.slurp;

        # Store the template path.
        %!templates{$t}<path> = $template;
        %!templates{$t}<file> = $template.slurp if $!cache-template;

        my Str $start-delim = @!token-delims[0];
        my Str $end-delim = @!token-delims[1];

        # Capture the start, end delim and the variable inside it. DO NOT
        # backtrack.
        with $f ~~ m:g/($start-delim): \s*: (<graph>+): \s*: ($end-delim):/ -> @m {
            # Initialize with an empty list.
            %!templates{$t}<vars> = [];

            # For every match we have start, end position of each
            # delim and the variable.
            #
            # We sort @m by the start delim's position. (Does some
            # magic, I have to comment it). It's important to mutate
            # the template file forwards only. Otherwise all the
            # calculations break.
            DELIM: for @m.sort(*[0].from).reverse -> $m {
                my Int $start-pos = $m[0].from;

                # If token-escape-char is set then we look behind for
                # it, if it is present then this token is skipped.
                with $!token-escape-char {
                    my Int $escape-char-start-pos = $start-pos - .chars;

                    # token can be at the beginning of file and that
                    # might cause substr() to fail so we first check
                    # for range.
                    if (.chars > 0 && $escape-char-start-pos > 0
                        && $f.substr($escape-char-start-pos, .chars) eq $_) {
                        # vars that have token-escape-char set as True are
                        # simply removed before render.
                        push %!templates{$t}<vars>, %(
                            token-escape-char => True,
                            start-pos => $escape-char-start-pos,
                            length => .chars
                        );
                        next DELIM;
                    }
                }

                # We need to extract the indent level of this
                # variable. If fixed-indent is True then this info is
                # used.
                my Int $indent-space;
                with $f.rindex("\n", $start-pos) -> $newline-pos {
                    $indent-space = $start-pos - $newline-pos - 1;
                } else {
                    $indent-space = $start-pos - 1;
                }

                # Store each variable alongside it's template file in
                # %!templates.
                push %!templates{$t}<vars>, %(
                    token-escape-char => False, # this is not an escape char
                    name      => $m[1].Str,
                    length    => ($m[2].to - $start-pos), # length to replace.
                    :$indent-space,
                    :$start-pos
                );
            }

            # Store template keys as unordered set. We need this later
            # to verify if template hash has all the required
            # variables.
            %!templates{$t}<keys> = Set.new( %!templates{$t}<vars>.map(*<name>) );
        }
    }

    #| get-default-value takes a key and returns the default value for
    #| it. It looks up the %defaults hash, if none is found then it
    #| returns an empty string.
    method !get-default-value($n --> Str) {
        my $value;

        with %!defaults {
            $value = %!defaults{$n};

            # if value not found in defaults hash then namespace and look
            # for value.
            if $!defaults-namespace-char.chars > 0 {
                without $value {
                    my @k = $n.split($!defaults-namespace-char).reverse;

                    $value = %!defaults{@k.pop};
                    while @k {
                        $value = $value{@k.pop};
                        last without $value;
                    }
                }
            }
        }

        return $value // '';
    }

    #| parse consumes values of keys of the template object and
    #| returns the final string that needs to be replaced with that
    #| key.
    #|
    #| my %t = %( TEMPLATE => 'test', xyz => 'hi' )
    #|
    #| parse here consumes 'xyz' and returns 'hi', it can also handle
    #| keys where the value is another Hash or a List.
    method !parse($var, Int $level! --> Str) {
        given $var {
            when Str  { return $var.Str }
            # trim-trailing to account for files ending on new line.
            when Hash { return self.render($var, $level + 1).trim-trailing }
            when List { return $var.map({self.render($_, $level + 1).trim-trailing}).join }
        }
    }

    #| render method renders the template, given a template hash.
    #| $level sets the indent level.
    method render(%t, Int $level = 0 --> Str) {
        die "Invalid template, no name-label [$!name-label]: {%t.gist}" without %t{$!name-label};
        die "Unrecognized template: {%t{$!name-label}}" without %!templates{%t{$!name-label}};

        # Get the indexed version of the template in %t-indexed.
        my %t-indexed := %!templates{%t{$!name-label}};

        # Check for bad-params if $!die-on-bad-params is set to
        # true. We check if the keys in template hash are all
        # present in template file except for the $!name-label.
        if $!die-on-bad-params == True && (%t.keys (-) %t-indexed<keys>) !(==) $!name-label {
            die "
                Variables in template hash: {%t.keys.grep(* ne $!name-label).sort.gist}
                Variables in template file: {%t-indexed<keys>.sort.gist}
                die-on-bad-params value: {$!die-on-bad-params}
                All variables in template hash must be valid if die-on-bad-params is True.";
        } else {
            my Str $rendered = %t-indexed<file> // %t-indexed<path>.slurp;

            # Loop over indexed variables, if a variable is not
            # defined in the template hash then we don't proceed.
            for @(%t-indexed<vars>) -> %v {
                # Remove escape characters from template file.
                if ($!token-escape-char.chars > 0 && %v<token-escape-char> == True) {
                    $rendered.substr-rw(%v<start-pos>, %v<length>) = '';
                } else {
                    # For variables that are not defined in template hash,
                    # replace them with empty string. If they exist in
                    # %!defaults then use those instead.
                    my Str $append = (%t{%v<name>}:exists)
                                         ?? self!parse(%t{%v<name>}, $level)
                                         !! self!get-default-value(%v<name>);

                    if $!fixed-indent == True {
                        $append .= subst("\n", "\n%s".sprintf(' ' x %v<indent-space>), :g);
                    }

                    # Replace the template variable.
                    $rendered.substr-rw(%v<start-pos>, %v<length>) = $append;
                }
            }

            # Add labels to the rendered string if $!show-labels is True.
            if $!show-labels == True {
                $rendered.substr-rw(0, 0) = "%s BEGIN %s %s\n".sprintf(
                    @!comment-delims[0], %t{$!name-label}, @!comment-delims[1]
                );

                $rendered.substr-rw($rendered.chars, 0) = "%s END %s %s\n".sprintf(
                    @!comment-delims[0], %t{$!name-label}, @!comment-delims[1]
                );
            }
            return $rendered;
        }
    }
}
