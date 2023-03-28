#| Template::Nest::Fast is a high-performance template engine module
#| for Raku, designed to process nested templates quickly and
#| efficiently. This module improves on the original Template::Nest
#| module by caching the index of positions of variables, resulting in
#| significantly faster processing times.
class Template::Nest::Fast {
    # has Str @!token-delims = ['<!--%', '%-->'];
    has Str $!name-label = 'TEMPLATE';
    has IO $.template-dir is required;

    # Template objects after compilation.
    has %!templates;

    #| TWEAK reads all the files in template-dir ending with '.html'
    #| extension and compiles them.
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
        self.compile($_) for @templates;
    }

    #| compile reads a template and prepares it for render.
    method compile(IO $template) {
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
                    name => ($m[1].Str),
                    start-delim => ($m[0].from, $m[0].to),
                    variable    => ($m[1].from, $m[1].to),
                    end-delim   => ($m[2].from, $m[2].to),
                    # Length of the string to replace.
                    length      => ($m[2].to - $m[0].from),
                );
            }
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
    method parse($var --> Str) {
        given $var {
            when Str  { return $var }
            when Hash { return self.render($var) }
            when List { return $var.map({self.render($_)}).join }
        }
    }

    method render(%t --> Str) {
        my Str $rendered;

        # After mutating the rendered string the positions of those
        # other variables that need to be substituted changes and so
        # we need to recalculate it, that is stored in this var.
        my int $delta = 0;

        with (%!templates{%t{$!name-label}}) -> %t-compiled {
            $rendered = %t-compiled<path>.slurp;

            for @(%t-compiled<vars>) -> %v {
                die "Variable {%v<name>} not defined." unless %t{%v<name>};

                # Replace the template variable.
                with self.parse(%t{%v<name>}) -> $append {
                    $rendered.substr-rw(%v<start-delim>[0] + $delta, %v<length>) = $append;

                    # From delta remove %v<length> and add the length
                    # of string we just appended.
                    $delta += - %v<length> + $append.chars;
                }
            }
        } else {
            die "Unrecognized template: {%t{$!name-label}}.";
        }
        return $rendered;
    }
}
