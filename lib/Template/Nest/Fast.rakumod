#| Template::Nest::Fast is a high-performance template engine module
#| for Raku, designed to process nested templates quickly and
#| efficiently. This module improves on the original Template::Nest
#| module by caching the index of positions of variables, resulting in
#| significantly faster processing times.
class Template::Nest::Fast {
    # has Str @!token-delims = ['<!--%', '%-->'];
    has Str $.name-label = 'TEMPLATE';
    has IO $.template-dir is required;

    # If True, then an attempt to populate a template with a variable
    # that doesn't exist (i.e. name not found in template) results in
    # an error.
    has Bool $.die-on-bad-params = True;

    # Template objects after compilation.
    has %!templates;

    #| TWEAK reads all the files in template-dir ending with '.html'
    #| extension and indexes them.
    submethod TWEAK() {
        # Grab all files ending with .html recursively.
        my IO @stack = $!template-dir, ;
        my IO @templates = gather while @stack {
            with @stack.pop {
                when :d { @stack.append: .dir }
                .take when .extension.lc eq 'html';
            }
        }

        # Render all the files.
        self!index-template($_) for @templates;
    }

    #| index-template reads a template and prepares it for render.
    method !index-template(IO $template) {
        # Get template name relative to $!template-dir and remove
        # `.html` extension.
        my Str $t = $template.relative($!template-dir).substr(0, *-5);

        my Str $f = $template.slurp;

        # Store the template path.
        %!templates{$t}<path> = $template;

        # Capture the start, end delim and the variable inside it. DO NOT
        # backtrack.
        with $f ~~ m:g/('<!--%'): \s*: (<[a..zA..Z0..9_-]>+): \s*: ('%-->'):/ -> @m {
            # Initialize with an empty list.
            %!templates{$t}<vars> = [];

            # For every match we have start, end position of each
            # delim and the variable.
            #
            # We sort @m by the start delim's position. (Does some
            # magic, I have to comment it)
            for @m.sort(*[0].from) -> $m {
                # Store each variable alongside it's template file in
                # %!templates.
                push %!templates{$t}<vars>, %(
                    name      => $m[1].Str,
                    start-pos => $m[0].from, # replace from.
                    length    => ($m[2].to - $m[0].from), # length to replace.
                );
            }

            # Store template keys as unordered set. We need this later
            # to verify if template hash has all the required
            # variables.
            %!templates{$t}<keys> = Set.new( %!templates{$t}<vars>.map(*<name>) );
        }
    }

    #| parse consumes values of keys of the template object and
    #| returns the final string that needs to be replaced with that
    #| key.
    #|
    #| my %t = %( TEMPLATE => 'test', xyz => 'hi' )
    #|
    #| parse here consumes 'xyz' and returns 'hi', it can also handle
    #| keys where the value is another Hash or a List.
    method !parse($var --> Str) {
        given $var {
            when Str  { return $var.Str }
            # trim-trailing to account for files ending on new line.
            when Hash { return self.render($var).trim-trailing }
            when List { return $var.map({self.render($_).trim-trailing}).join }
        }
    }

    method render(%t --> Str) {
        die "Invalid template, no name-label: {%t}" without %t{$!name-label};

        my Str $rendered;

        # After mutating the rendered string the positions of those
        # other variables that need to be substituted changes and so
        # we need to recalculate it, that is stored in this var.
        my int $delta = 0;

        # Get the indexed version of the template in %t-indexed.
        with (%!templates{%t{$!name-label}}) -> %t-indexed {
            # Read the file.
            $rendered = %t-indexed<path>.slurp;

            # Check for bad-params if $!die-on-bad-params is set to
            # true. We check if the keys in template hash are all
            # present in template file except for the $!name-label.
            if $!die-on-bad-params && (%t.keys (-) %t-indexed<keys>) !(==) $!name-label {
                die qq:to/END/;
                Variables in template hash: {%t.keys.grep(* ne $!name-label).sort.gist}
                Variables in template file: {%t-indexed<keys>.sort.gist}
                die-on-bad-params value: {$!die-on-bad-params}
                All variables in template hash must be valid if die-on-bad-params is True.
                END
            }

            # Loop over indexed variables, if a variable is not
            # defined in the template hash then we don't proceed.
            for @(%t-indexed<vars>) -> %v {
                # For variables that are not defined in template hash,
                # replace them with empty string.
                my Str $append = (%t{%v<name>}:exists)
                                     ?? self!parse(%t{%v<name>})
                                     !! '';
                # Replace the template variable.
                $rendered.substr-rw(%v<start-pos> + $delta, %v<length>) = $append;

                # From delta remove %v<length> and add the length
                # of string we just appended.
                $delta += - %v<length> + $append.chars;
            }
        } else {
            die "Unrecognized template: {%t{$!name-label}}.";
        }
        return $rendered;
    }
}
