package DBIx::Perlish::Parse;
# $Id: Parse.pm,v 1.47 2007/02/21 18:59:16 tobez Exp $
use 5.008;
use warnings;
use strict;

our $DEVEL;

use B;
use Carp;

sub bailout
{
	my ($S, @rest) = @_;
	if ($DEVEL) {
		confess @rest;
	} else {
		my $args = join '', @rest;
		$args = "Something's wrong" unless $args;
		my $file = $S->{file};
		my $line = $S->{line};
		$args .= " at $file line $line.\n"
			unless substr($args, length($args) -1) eq "\n";
		CORE::die($args);
	}
}

# "is" checks

sub is
{
	my ($optype, $op, $name) = @_;
	return 0 unless ref($op) eq $optype;
	return 1 unless $name;
	return $op->name eq $name;
}

sub gen_is
{
	my ($optype) = @_;
	my $pkg = "B::" . uc($optype);
	eval qq[ sub is_$optype { is("$pkg", \@_) } ] unless __PACKAGE__->can("is_$optype");
}

gen_is("binop");
gen_is("cop");
gen_is("listop");
gen_is("logop");
gen_is("loop");
gen_is("null");
gen_is("op");
gen_is("padop");
gen_is("svop");
gen_is("unop");

sub is_const
{
	my ($S, $op) = @_;
	return () unless is_svop($op, "const");
	my $sv = $op->sv;
	if (!$$sv) {
		$sv = $S->{padlist}->[1]->ARRAYelt($op->targ);
	}
	if (wantarray) {
		return (${$sv->object_2svref}, $sv);
	} else {
		return ${$sv->object_2svref};
	}
}

# "want" helpers

sub gen_want
{
	my ($optype, $return) = @_;
	if (!$return) {
		$return = '$op';
	} elsif ($return =~ /^\w+$/) {
		$return = '$op->' . $return;
	}
	eval <<EOF unless __PACKAGE__->can("want_$optype");
	sub want_$optype {
		my (\$S, \$op, \$n) = \@_;
		unless (is_$optype(\$op, \$n)) {
			bailout \$S, "want $optype" unless \$n;
			bailout \$S, "want $optype \$n";
		}
		$return;
	}
EOF
}

gen_want("op");
gen_want("unop", "first");
gen_want("listop", 'get_all_children($op)');
gen_want("svop", "sv");
gen_want("null");

sub want_const
{
	my ($S, $op) = @_;
	my $sv = want_svop($S, $op, "const");
	if (!$$sv) {
		$sv = $S->{padlist}->[1]->ARRAYelt($op->targ);
	}
	${$sv->object_2svref};
}

sub want_method
{
	my ($S, $op) = @_;
	my $sv = want_svop($S, $op, "method_named");
	if (!$$sv) {
		$sv = $S->{padlist}->[1]->ARRAYelt($op->targ);
	}
	${$sv->object_2svref};
}

# getters

sub get_all_children
{
	my ($op) = @_;
	my $c = $op->children;
	my @op;
	return @op unless $c;
	push @op, $op->first;
	while (--$c) {
		push @op, $op[-1]->sibling;
	}
	@op;
}

sub padname
{
	my ($S, $op, %p) = @_;

	my $padname = $S->{padlist}->[0]->ARRAYelt($op->targ);
	if ($padname && ref($padname) ne "B::SPECIAL") {
		return if $p{no_fakes} && $padname->FLAGS & B::SVf_FAKE;
		return "my " . $padname->PVX;
	} else {
		return "my #" . $op->targ;
	}
}

sub get_value
{
	my ($S, $op, %p) = @_;

	my $val;
	if (is_op($op, "padsv")) {
		if (find_aliased_tab($S, $op)) {
			bailout $S, "cannot use a table variable as a value";
		}
		my $vv = $S->{padlist}->[1]->ARRAYelt($op->targ)->object_2svref;
		$val = $$vv;
	} elsif (is_binop($op, "helem")) {
		my $key = is_const($S, $op->last);
		bailout $S, "only constant hash keys are understood" unless $key;
		$op = $op->first;
		my $vv;
		if (is_op($op, "padhv")) {
			$vv = $S->{padlist}->[1]->ARRAYelt($op->targ)->object_2svref;
		} elsif (is_unop($op, "rv2hv")) {
			$op = $op->first;
			if (is_op($op, "padsv")) {
				if (find_aliased_tab($S, $op)) {
					bailout $S, "cannot use a table variable as a value";
				}
				$vv = $S->{padlist}->[1]->ARRAYelt($op->targ)->object_2svref;
				$vv = $$vv;
			}
		}
		bailout $S, "unable to extract a value from a hash(ref)" unless $vv;
		$val = $vv->{$key};
	} else {
		return () if $p{soft};
		bailout $S, "cannot parse \"", $op->name, "\" op as a value or value reference";
	}
	return ($val, 1);
}

sub get_var
{
	my ($S, $op) = @_;
	if (is_op($op, "padsv")) {
		return padname($S, $op);
	} elsif (is_unop($op, "null")) {
		$op = $op->first;
		want_svop($S, $op, "gvsv");
		return "*" . $op->gv->NAME;
	} else {
	# XXX
		print "$op\n";
		print "type: ", $op->type, "\n";
		print "name: ", $op->name, "\n";
		print "desc: ", $op->desc, "\n";
		print "targ: ", $op->targ, "\n";
		bailout $S, "cannot get var";
	}
}

sub find_aliased_tab
{
	my ($S, $op) = @_;
	my $var = padname($S, $op);
	my $ss = $S;
	while ($ss) {
		my $tab;
		if ($ss->{operation} eq "select") {
			$tab = $ss->{var_alias}{$var};
		} else {
			$tab = $ss->{vars}{$var};
		}
		return $tab if $tab;
		$ss = $ss->{gen_args}->{prev_S};
	}
	return "";
}

sub get_tab_field
{
	my ($S, $unop, %p) = @_;
	my $op = want_unop($S, $unop, "entersub");
	want_op($S, $op, "pushmark");
	$op = $op->sibling;
	my $tab = is_const($S, $op);
	if ($tab) {
		$tab = new_tab($S, $tab);
	} elsif (is_op($op, "padsv")) {
		$tab = find_aliased_tab($S, $op);
	}
	unless ($tab) {
		bailout $S, "cannot get a table";
	}
	$op = $op->sibling;
	my $field = want_method($S, $op);
	$op = $op->sibling;
	if ($p{lvalue}) {
		want_unop($S, $op, "rv2cv");
		$op = $op->sibling;
	}
	want_null($S, $op);
	if ($S->{parsing_return} && !$S->{inside_aggregate}) {
		my $ff = $S->{operation} eq "select" ? "$tab.$field" : $field;
		push @{$S->{autogroup_by}}, $ff unless $S->{autogroup_fields}{$ff}++;
	}
	($tab, $field);
}

# helpers

sub maybe_one_table_only
{
	my ($S) = @_;
	return if $S->{operation} eq "select";
	if ($S->{tabs} && keys %{$S->{tabs}} or $S->{vars} && keys %{$S->{vars}}) {
		bailout $S, "a $S->{operation}'s query sub can only refer to a single table";
	}
}

sub new_tab
{
	my ($S, $tab) = @_;
	unless ($S->{tabs}{$tab}) {
		maybe_one_table_only($S);
		$S->{tabs}{$tab} = 1;
		$S->{tab_alias}{$tab} = $S->{alias};
		$S->{alias}++;
	}
	$S->{tab_alias}{$tab};
}

sub new_var
{
	my ($S, $var, $tab) = @_;
	maybe_one_table_only($S);
	bailout $S, "cannot reuse $var for table $tab, it's already used by $S->{vars}{$var}"
		if $S->{vars}{$var};
	$S->{vars}{$var} = $tab;
	$S->{var_alias}{$var} = $S->{alias};
	$S->{alias}++;
}

# parsers

sub try_parse_attr_assignment
{
	my ($S, $op, $realname) = @_;
	return unless is_unop($op, "entersub");
	$op = want_unop($S, $op);
	return unless is_op($op, "pushmark");
	$op = $op->sibling;
	my $c = is_const($S, $op);
	return unless $c && $c eq "attributes";
	$op = $op->sibling;
	return unless is_const($S, $op);
	$op = $op->sibling;
	return unless is_unop($op, "srefgen");
	my $op1 = want_unop($S, $op);
	$op1 = want_unop($S, $op1) if is_unop($op1, "null");
	return unless is_op($op1, "padsv");
	my $varn = padname($S, $op1);
	$op = $op->sibling;
	my $attr = is_const($S, $op);
	return unless $attr;
	$op = $op->sibling;
	return unless is_svop($op, "method_named");
	return unless want_method($S, $op, "import");
	if ($realname) {
		if (lc $attr eq "table") {
			$attr = $realname;
		} else {
			bailout $S, "cannot decide whether you refer to $realname table or to $attr table";
		}
	}
	new_var($S, $varn, $attr);
	return $attr;
}

sub parse_list
{
	my ($S, $op) = @_;
	my @op = get_all_children($op);
	for $op (@op) {
		parse_op($S, $op);
	}
}

sub parse_return
{
	my ($S, $op) = @_;
	my @op = get_all_children($op);
	bailout $S, "there should be no \"return\" statements in $S->{operation}'s query sub"
		unless $S->{operation} eq "select";
	bailout $S, "there should be at most one return statement" if $S->{returns};
	$S->{returns} = [];
	my $last_alias;
	for $op (@op) {
		my %rv = parse_return_value($S, $op);
		if (exists $rv{table}) {
			bailout $S, "cannot alias the whole table"
				if defined $last_alias;
			push @{$S->{returns}}, "$rv{table}.*";
			$S->{no_autogroup} = 1;
		} if (exists $rv{field}) {
			if (defined $last_alias) {
				push @{$S->{returns}}, "$rv{field} as $last_alias";
				undef $last_alias;
			} else {
				push @{$S->{returns}}, $rv{field};
			}
		} elsif (exists $rv{alias}) {
			bailout $S, "bad alias name \"$rv{alias}\""
				unless $rv{alias} =~ /^\w+$/;
			bailout $S, "cannot alias an alias"
				if defined $last_alias;
			if (lc $rv{alias} eq "distinct") {
				bailout $S, "\"$rv{alias}\" is not a valid alias name" if @{$S->{returns}};
				$S->{distinct}++;
				next;
			}
			$last_alias = $rv{alias};
		}
	}
}

sub parse_return_value
{
	my ($S, $op) = @_;

	if (is_op($op, "padsv")) {
		return table => find_aliased_tab($S, $op);
	} elsif (my $const = is_const($S, $op)) {
		return alias => $const;
	} elsif (is_op($op, "pushmark")) {
		return ();
	} else {
		my $saved_values = $S->{values};
		$S->{values} = [];
		$S->{parsing_return} = 1;
		my $ret = parse_term($S, $op);
		$S->{parsing_return} = 0;
		push @{$S->{ret_values}}, @{$S->{values}};
		$S->{values} = $saved_values;
		return field => $ret;
	}
}

sub parse_term
{
	my ($S, $op, %p) = @_;

	if (is_unop($op, "entersub")) {
		my $funcall = try_funcall($S, $op);
		return $funcall if defined $funcall;
		my ($t, $f) = get_tab_field($S, $op);
		if ($S->{operation} eq "delete" || $S->{operation} eq "update") {
			return $f;
		} else {
			return "$t.$f";
		}
	} elsif (is_unop($op, "lc")) {
		my $term = parse_term($S, $op->first);
		return "lower($term)";
	} elsif (is_unop($op, "uc")) {
		my $term = parse_term($S, $op->first);
		return "upper($term)";
	} elsif (is_unop($op, "abs")) {
		my $term = parse_term($S, $op->first);
		return "abs($term)";
	} elsif (is_unop($op, "null")) {
		return parse_term($S, $op->first, %p);
	} elsif (is_op($op, "null")) {
		return parse_term($S, $op->sibling, %p);
	} elsif (is_op($op, "undef")) {
		return "null";
	} elsif (is_unop($op, "not")) {
		my $subop = $op-> first;
		if (ref($subop) eq "B::PMOP" && $subop->name eq "match") {
			return parse_regex( $S, $subop, 1);
		} else {
			my ($term, $with_not) = parse_term($S, $subop);
			if ($p{not_after}) {
				return "$term not";
			} elsif ($with_not) {
				return $with_not;
			} else {
				return "not $term";
			}
		}
	} elsif (is_unop($op, "defined")) {
		my $term = parse_term($S, $op->first);
		return wantarray ?
			("$term is not null", "$term is null") :
			"$term is not null";
	} elsif (my ($val, $ok) = get_value($S, $op, soft => 1)) {
		if (defined $val) {
			push @{$S->{values}}, $val;
			return "?";
		} else {
			return "null";
		}
	} elsif (is_binop($op)) {
		my $expr = parse_expr($S, $op);
		return "($expr)";
	} elsif (is_logop($op, "or")) {
		my $or = parse_or($S, $op);
		bailout $S, "looks like a limiting range inside an expression\n"
			unless $or;
		return "($or)";
	} elsif (my ($const,$sv) = is_const($S, $op)) {
		if (ref $sv eq "B::IV" || ref $sv eq "B::NV") {
			# This is surely a number, so we can
			# safely inline it in the SQL.
			return $const;
		} else {
			# This will probably be represented by a string,
			# we'll let DBI to handle the quoting of a bound
			# value.
			push @{$S->{values}}, $const;
			return "?";
		}
	} else {
		bailout $S, "cannot reconstruct term from operation \"",
				$op->name, '"';
	}
}

## XXX above this point 80.parse_bad.t did not go

sub parse_simple_term
{
	my ($S, $op) = @_;
	if (my $const = is_const($S, $op)) {
		return $const;
	} elsif (my ($val, $ok) = get_value($S, $op, soft => 1)) {
		return $val;
	} else {
		bailout $S, "cannot reconstruct simple term from operation \"",
				$op->name, '"';
	}
}

sub get_gv
{
	my ($S, $op) = @_;

	my ($gv_on_pad, $gv_idx);
	if (is_svop($op, "gv")) {
		$gv_idx = $op->targ;
	} elsif (is_padop($op, "gv")) {
		$gv_idx = $op->padix;
		$gv_on_pad = 1;
	} else {
		return;
	}
	return unless is_null($op->sibling);

	my $gv = $gv_on_pad ? "" : $op->sv;
	if (!$gv || !$$gv) {
		$gv = $S->{padlist}->[1]->ARRAYelt($gv_idx);
	}
	return unless ref $gv eq "B::GV";
	$gv;
}

sub try_get_dbfetch
{
	my ($S, $sub) = @_;
		
	return unless is_unop($sub, "entersub");
	$sub = $sub->first if is_unop($sub->first, "null");
	return unless is_op($sub->first, "pushmark");

	my $rg = $sub->first->sibling;
	return if is_null($rg);
	my $dbfetch = $rg->sibling;
	return if is_null($dbfetch);
	return unless is_null($dbfetch->sibling);

	return unless is_unop($rg, "refgen");
	$rg = $rg->first if is_unop($rg->first, "null");
	return unless is_op($rg->first, "pushmark");
	my $codeop = $rg->first->sibling;
	return unless is_svop($codeop, "anoncode");

	$dbfetch = $dbfetch->first if is_unop($dbfetch->first, "null");
	$dbfetch = $dbfetch->first;
	my $gv = get_gv($S, $dbfetch);
	return unless $gv;
	return unless $gv->NAME eq "db_fetch";

	return $codeop;
}

sub try_parse_subselect
{
	my ($S, $sop) = @_;
	my $sql;
	my @vals;

	my $sub = $sop->last->first;

	if (is_op($sub, "padav")) {
		my $ary = $S->{padlist}->[1]->ARRAYelt($sub->targ)->object_2svref;
		bailout $S, "empty array in not valid in \"<-\"" unless @$ary;
		$sql = join ",", ("?") x @$ary;
		@vals = @$ary;
	} else {
		my $codeop = try_get_dbfetch( $S, $sub);
		return unless $codeop;
		$sql = handle_subselect($S, $codeop);
	}

	my $left = parse_term($S, $sop->first, not_after => 1);
	push @{$S->{values}}, @vals;
	return "$left in ($sql)";
}

sub handle_subselect
{
	my ($S, $codeop, %p) = @_;

	my $cv = $codeop->sv;
	if (!$$cv) {
		$cv = $S->{padlist}->[1]->ARRAYelt($codeop->targ);
	}
	my $subref = $cv->object_2svref;

	my %gen_args = %{$S->{gen_args}};
	$gen_args{prev_S} = $S;
	if ($gen_args{prefix}) {
		$gen_args{prefix} = "$gen_args{prefix}_$S->{subselect}";
	} else {
		$gen_args{prefix} = $S->{subselect};
	}
	$S->{subselect}++;
	my ($sql, $vals, $nret) = DBIx::Perlish::gen_sql($subref, "select",
		%gen_args);
	if ($nret != 1 && !$p{returns_dont_care}) {
		bailout $S, "subselect query sub must return exactly one value\n";
	}

	push @{$S->{values}}, @$vals;
	return $sql;
}

sub parse_assign
{
	my ($S, $op) = @_;

	if (is_listop($op->last, "list") &&
		is_op($op->last->first, "pushmark") &&
		is_unop($op->last->first->sibling, "entersub"))
	{
		my ($val, $ok) = get_value($S, $op->first, soft => 1);
		if ($ok) {
			my $tab = try_parse_attr_assignment($S,
				$op->last->first->sibling, $val);
			return if $tab;
		}
	}
	bailout $S, "assignments are not understood in $S->{operation}'s query sub"
		unless $S->{operation} eq "update";
	if (is_unop($op->first, "srefgen")) {
		parse_multi_assign($S, $op);
	} else {
		parse_simple_assign($S, $op);
	}
}

sub parse_simple_assign
{
	my ($S, $op) = @_;

	my ($tab, $f) = get_tab_field($S, $op->last, lvalue => 1);
	my $saved_values = $S->{values};
	$S->{values} = [];
	my $set = parse_term($S, $op->first);
	push @{$S->{set_values}}, @{$S->{values}};
	$S->{values} = $saved_values;
	push @{$S->{sets}}, "$f = $set";
}

sub callarg
{
	my ($S, $op) = @_;
	$op = $op->first if is_unop($op, "null");
	return () if is_op($op, "pushmark");
	return $op;
}

sub try_funcall
{
	my ($S, $op) = @_;
	my @args;
	if (is_unop($op, "entersub")) {
		$op = $op->first;
		$op = $op->first if is_unop($op, "null");
		while (1) {
			last if is_null($op);
			push @args, callarg($S, $op);
			$op = $op->sibling;
		}
		return unless @args;
		$op = pop @args;
		return unless is_svop($op, "gv") || is_padop($op, "gv");
		my $gv = get_gv($S, $op);
		return unless $gv;
		my $func = $gv->NAME;
		if ($func =~ /^(db_fetch|union|intersect|except)$/) {
			return unless @args == 1;
			my $rg = $args[0];
			return unless is_unop($rg, "refgen");
			$rg = $rg->first if is_unop($rg->first, "null");
			return unless is_op($rg->first, "pushmark");
			my $codeop = $rg->first->sibling;
			return unless is_svop($codeop, "anoncode");
			if ($func eq "db_fetch") {
				my $sql = handle_subselect($S, $codeop, returns_dont_care => 1);
				return "exists ($sql)";
			} else {
				return unless $S->{operation} eq "select";
				my $cv = $codeop->sv;
				if (!$$cv) {
					$cv = $S->{padlist}->[1]->ARRAYelt($codeop->targ);
				}
				my $subref = $cv->object_2svref;
				my %gen_args = %{$S->{gen_args}};
				my ($sql, $vals, $nret) = DBIx::Perlish::gen_sql($subref, "select",
					%gen_args);
				# XXX maybe check for nret validity
				push @{$S->{additions}}, {
					type => $func,
					sql  => $sql,
					vals => $vals,
				};
				return "";
			}
		} elsif ($func eq "sql") {
			return unless @args == 1;
			# XXX understand more complex expressions here
			my $sql;
			return unless $sql = is_const($S, $args[0]);
			return $sql;
		}
		if ($S->{parsing_return} && $S->{aggregates}{lc $func}) {
			$S->{autogroup_needed} = 1;
			$S->{inside_aggregate} = 1;
		}

		my @terms = map { scalar parse_term($S, $_) } @args;

		if ($S->{parsing_return} && $S->{aggregates}{lc $func}) {
			$S->{inside_aggregate} = 0;
		}

		return "sysdate"
			if ($S->{gen_args}->{flavor}||"") eq "Oracle" &&
				lc $func eq "sysdate" && !@terms;
		return "$func(" . join(", ", @terms) . ")";
	}
}

sub parse_multi_assign
{
	my ($S, $op) = @_;

	my $hashop = $op->first;
	want_unop($S, $hashop, "srefgen");
	$hashop = $hashop->first;
	$hashop = $hashop->first while is_unop($hashop, "null");
	want_listop($S, $hashop, "anonhash");

	my $saved_values = $S->{values};
	$S->{values} = [];

	my $want_const = 1;
	my $field;
	for my $c (get_all_children($hashop)) {
		next if is_op($c, "pushmark");
		if ($want_const) {
			$field = want_const($S, $c);
			$want_const = 0;
		} else {
			my $set = parse_term($S, $c);
			push @{$S->{set_values}}, @{$S->{values}};
			push @{$S->{sets}}, "$field = $set";
			$S->{values} = [];
			$want_const = 1;
			$field = undef;
		}
	}

	$S->{values} = $saved_values;

	$op = $op->last;

	my $tab;
	if (is_op($op, "padsv")) {
		my $var = get_var($S, $op);
		$tab = $S->{vars}{$var};
	} elsif (is_unop($op, "entersub")) {
		$op = $op->first;
		$op = $op->first if is_unop($op, "null");
		$op = $op->sibling if is_op($op, "pushmark");
		$op = $op->first if is_unop($op, "rv2cv");
		my $gv = get_gv($S, $op);
		$tab = $gv->NAME if $gv;
	}
	bailout $S, "cannot get a table to update" unless $tab;
}

my %binop_map = (
	eq       => "=",
	seq      => "=",
	ne       => "<>",
	sne      => "<>",
	slt      => "<",
	gt       => ">",
	sgt      => ">",
	le       => "<=",
	sle      => "<=",
	ge       => ">=",
	sge      => ">=",
	add      => "+",
	subtract => "-",
	multiply => "*",
	divide   => "/",
	concat   => "||",
);

sub parse_expr
{
	my ($S, $op) = @_;
	my $sqlop;
	if (is_binop($op, "concat")) {
		my ($c, $v) = try_special_concat($S, $op);
		if ($c) {
			push @{$S->{values}}, @$v;
			return $c;
		}
	}
	if ($sqlop = $binop_map{$op->name}) {
		my $left = parse_term($S, $op->first);
		my $right = parse_term($S, $op->last);
		if ($sqlop eq "=" || $sqlop eq "<>") {
			my $not = $sqlop eq "<>" ? " not" : "";
			if ($right eq "null") {
				return "$left is$not null";
			} elsif ($left eq "null") {
				return "$right is$not null";
			}
		}
		return "$left $sqlop $right";
	} elsif ($op->name eq "lt") {
		if (is_unop($op->last, "negate")) {
			my $r = try_parse_subselect($S, $op);
			return $r if $r;
		}
		# if the "subselect theory" fails, try a normal binop
		my $left = parse_term($S, $op->first);
		my $right = parse_term($S, $op->last);
		return "$left < $right";
	} elsif ($op->name eq "sassign") {
		parse_assign($S, $op);
		return ();
	} else {
		bailout $S, "unsupported binop " . $op->name;
	}
}

sub try_special_concat
{
	my ($S, $op, $no_processing) = @_;
	my @terms;
	my $str;
	if (is_binop($op, "concat")) {
		my @t = try_special_concat($S, $op->first, "don't process");
		return () unless @t;
		push @terms, @t;
		@t = try_special_concat($S, $op->last, "don't process");
		return () unless @t;
		push @terms, @t;
	} elsif (($str = is_const($S, $op))) {
		push @terms, {str => $str};
	} elsif (is_unop($op, "null")) {
		$op = $op->first;
		while (!is_null($op)) {
			my @t = try_special_concat($S, $op, "don't process");
			return () unless @t;
			push @terms, @t;
			$op = $op->sibling;
		}
	} elsif (is_op($op, "null")) {
		return {skip => 1};
	} elsif (is_binop($op, "helem")) {
		my $f = is_const($S, $op->last);
		return () unless $f;
		$op = $op->first;
		return () unless is_unop($op, "rv2hv");
		$op = $op->first;
		return () unless is_op($op, "padsv");
		my $tab = find_aliased_tab($S, $op);
		return () unless $tab;
		push @terms, {tab => $tab, field => $f};
	} elsif (is_unop($op, "entersub")) {
		my ($t, $f) = eval { get_tab_field($S, $op) };
		return () unless $f;
		push @terms, {tab => $t, field => $f};
	} elsif (is_op($op, "padsv")) {
		my $tab = find_aliased_tab($S, $op);
		return () unless $tab;
		push @terms, {tab => $tab};
	} else {
		return ();
	}
	return @terms if $no_processing;
	$str = "";
	my @sql;
	my @v;
	@terms = grep { !$_->{skip} } @terms;
	while (@terms) {
		my $t = shift @terms;
		if ($t->{str}) {
			$str .= $t->{str};
		} elsif ($t->{field}) {
			if ($str) {
				push @v, $str;
				push @sql, '?';
			}
			if ($S->{operation} eq "delete" || $S->{operation} eq "update") {
				push @sql, $t->{field};
			} else {
				push @sql, "$t->{tab}.$t->{field}";
			}
			$str = "";
		} else {
			my $t2 = shift @terms;
			return () unless $t2;
			return () unless $t2->{str};
			return () unless $t2->{str} =~ s/^->(\w+)//;
			my $f = $1;
			if ($str) {
				push @v, $str;
				push @sql, '?';
			}
			if ($S->{operation} eq "delete" || $S->{operation} eq "update") {
				push @sql, $f;
			} else {
				push @sql, "$t->{tab}.$f";
			}
			$str = $t2->{str};
		}
	}
	if ($str) {
		push @v, $str;
		push @sql, '?';
	}
	my $sql = join " || ", @sql;
	return ($sql, \@v);
}

sub parse_entersub
{
	my ($S, $op) = @_;
	my $tab = try_parse_attr_assignment($S, $op);
	return () if $tab;
	return scalar parse_term($S, $op);
}

sub parse_complex_regex
{
	my ( $S, $op) = @_;

	if ( is_unop( $op)) {
		return parse_complex_regex( $S, $op-> first);
	} elsif ( is_binop( $op, 'concat')) {
		$op = $op-> first;
		return 
			parse_complex_regex( $S, $op) . 
			parse_complex_regex( $S, $op-> sibling)
		;
	} elsif ( is_svop( $op, 'const')) {
		return want_const( $S, $op);
	} elsif (my ($rx, $ok) = get_value($S, $op, soft => 1)) {
		$rx =~ s/^\(\?\-\w*\:(.*)\)$/$1/; # (?-xism:moo) -> moo
		return $rx;
	} else {
		bailout $S, "unsupported op " . ref($op) . '/' . $op->name; 
	}
}

sub parse_regex
{
	my ( $S, $op, $neg) = @_;
	my ( $like, $case) = ( $op->precomp, $op-> pmflags & B::PMf_FOLD);

	unless ( defined $like) {
		my $logop = $op-> first-> sibling;
		bailout $S, "strange regex " . $op->name
			unless $logop and is_logop( $logop, 'regcomp');
		$like = parse_complex_regex( $S, $logop-> first);
	}

	my ($tab, $field) = get_tab_field($S, $op->first);

	my $flavor = lc($S-> {gen_args}-> {flavor} || '');
	my $what = 'like';

	my $can_like = $like =~ /^\^?[-\s\w]*\$?$/; # like that begins with non-% can use indexes
	
	if ( $flavor eq 'mysql') {
	
		# mysql LIKE is case-insensitive
		goto LIKE if not $case and $can_like;

		return 
			"$tab.$field ".
			( $neg ? 'not ' : '') . 
			'regexp ' .
			( $case ? '' : 'binary ') .
			"'$like'"
			;
	} elsif ( $flavor eq 'postgresql') {
		# LIKE is case-sensitive
		if ( $can_like) {
			$what = 'ilike' if $case;
			goto LIKE;
		} 
		return 
			"$tab.$field ".
			( $neg ? '!' : '') . 
			'~' .
			( $case ? '*' : '') .
			" '$like'"
			;
	} elsif ( $flavor eq 'sqlite') {
		# SQLite as it is now is a bit tricky:
		# - there is support for REGEXP with a func provided the user
		#   supplies his own function;
		# - LIKE is case-insensitive (for ASCII, anyway, there's a bug there);
		# - GLOB is case-sensitive;
		# - there is also support for MATCH - with a user func
		# Since it does not appear that SQLite can use indices
		# for prefix matches with simple LIKE statements, we
		# just hijack REGEXP and MATCH for case-sensitive
		# and case-insensitive cases.  If I am wrong on that,
		# or if SQLite gets and ability to do index-based
		# prefix matching, this logic can be modified accordingly.
		if ($case) {
			$what = "match";
			$S->{gen_args}->{dbh}->func($what, 2, sub {
				return scalar $_[1] =~ /\Q$_[0]\E/i;
			}, "create_function");
		} else {
			$what = "regexp";
			$S->{gen_args}->{dbh}->func($what, 2, sub {
				return scalar $_[1] =~ /\Q$_[0]\E/;
			}, "create_function");
		}
		push @{$S->{values}}, $like;
		# $what = $neg ? "not $what" : $what;
		# return "$tab.$field $what ?";
		return ($neg ? "not " : "") . "$what(?, $tab.$field)";
	} else {
		# XXX is SQL-standard LIKE case-sensitive or not?
		bailout $S, "Don't know how to set case-insensitive flag for this DBI flavor"
			if $case;
		bailout $S, "Regex too complex for implementation using LIKE keyword: $like"
			if $like =~ /(?<!\\)[\[\]\(\)\{\}\?\|]/;
LIKE:
		$like =~ s/%/\\%/g;
		$like =~ s/_/\\_/g;
		$like =~ s/\.\*/%/g;
		$like =~ s/\./_/g;
		$like = "%$like" unless $like =~ s|^\^||;
		$like = "$like%" unless $like =~ s|\$$||;
		return "$tab.$field " . 
			( $neg ? 'not ' : '') . 
			"$what '$like'"
		;
	}
}

my %join_map = (
	bit_and  => "inner",
	multiply => "inner",
	repeat   => "inner",
	bit_or   => "full outer",
	add      => "full outer",
	lt       => "left outer",
	gt       => "right outer",
);

sub parse_join
{
	my ($S, $op) = @_;
	my @op = get_all_children( $op);


	# allow 2-arg syntax for cross joins:
	#    join $a * $b
	# and 3-arg syntax for all other joins:
	#    join $a * $b => db_fetch { ... }
	bailout $S, "not a valid join() syntax"
		unless 2 <= @op and 3 >= @op and
			$op[0]-> name eq 'pushmark' and 
			is_binop( $op[1]);
	my $jointype;
	if ( 2 == @op) {
		bailout $S, "not a valid join() syntax: one of &,*,x is expected"
			unless 
				exists $join_map{ $op[1]-> name } and
				$join_map{ $op[1]-> name } eq 'inner';
		$jointype = 'cross';
	} else {
		bailout $S, "not a valid join() syntax: one of &,|,x,+,*,<,> is expected"
			unless exists $join_map{ $op[1]-> name };
		bailout $S, "not a valid join() syntax"
			unless is_unop( $op[2]) and $op[2]-> name eq 'entersub';
		$jointype = $join_map{ $op[1]-> name };
	}

	# table names
	my @tab;
	$tab[0] = find_aliased_tab($S, $op[1]-> first) or 
		bailout $S, "first argument join() is not a table";
	$tab[1] = find_aliased_tab($S, $op[1]-> last) or 
		bailout $S, "second argument join() is not a table";
	
	# db_fetch
	my ( $condition, $codeop);
	if ( $op[2]) {
		$codeop = try_get_dbfetch( $S, $op[2]);
		bailout $S, "third argument to join is not a db_fetch expression"
			unless $codeop;

		my $cv = $codeop->sv;
		if (!$$cv) {
			$cv = $S->{padlist}->[1]->ARRAYelt($codeop->targ);
		}
		my $subref = $cv->object_2svref;
		my $S2 = init( 
			%{$S->{gen_args}}, 
			operation => 'select',
			prev_S    => $S,
		);
		$S2-> {alias} = $S-> {alias};
		parse_sub($S2, $subref);
		bailout $S, 
			"join() db_fetch expression cannot contain anything ".
			"but conditional expressions on already declared tables"
				if scalar( grep { @{ $S2-> {$_} } } qw(
					group_by order_by autogroup_by ret_values joins
				)) or $S2->{alias} ne $S->{alias};

		unless ( @{ $S2->{where}||[] }) {
			bailout $S, 
				"join() db_fetch expression must contain ".
				"at least one conditional expression"
					unless $jointype eq 'inner';
			$jointype = 'cross';
		} else {
			$condition = join(' and ', @{ $S2-> {where} });
		}
	}

	return [ $jointype, @tab, $condition ];
}

sub try_parse_range
{
	my ($S, $op) = @_;
	return try_parse_range($S, $op->first) if is_unop($op, "null");
	return unless is_unop($op, "flop");
	$op = $op->first;
	return unless is_unop($op, "flip");
	$op = $op->first;
	return unless is_logop($op, "range");
	return (parse_simple_term($S, $op->first),
			parse_simple_term($S, $op->first->sibling));
}

sub parse_or
{
	my ($S, $op) = @_;
	if (is_op($op->first->sibling, "last")) {
		bailout $S, "there should be no \"last\" statements in $S->{operation}'s query sub"
			unless $S->{operation} eq "select";
		my ($from, $to) = try_parse_range($S, $op->first);
		bailout $S, "range operator expected" unless defined $to;
		$S->{offset} = $from;
		$S->{limit}  = $to-$from+1;
		return;
	} else {
		my $left  = parse_term($S, $op->first);
		my $right = parse_term($S, $op->first->sibling);
		return "$left or $right";
	}
}

sub parse_and
{
	my ($S, $op) = @_;
	if (my ($val, $ok) = get_value($S, $op->first, soft => 1)) {
		if ($val) {
			$op = $op->first->sibling;
			# This strangeness is for suppressing () when parsing
			# expr via parse_term.  There must be a better way.
			if (is_binop($op) || $op->name eq "sassign") {
				return parse_expr($S, $op);
			} else {
				return scalar parse_term($S, $op);
			}
		} else {
			return ();
		}
	} else {
		bailout $S, "logical AND is not supported yet";
	}
}

my $action_orderby = {
	kind => 'termlist',
	key  => 'order_by',
};
my $action_groupby = {
	kind => 'fieldlist',
	key  => 'group_by',
};
my $action_limit = {
	kind => 'numassign',
	key  => 'limit',
};
my $action_offset = {
	kind => 'numassign',
	key  => 'offset',
};
my $action_distinct = {
	kind => 'notice',
	key  => 'distinct',
};
my %labelmap = (
	select => {
		orderby   => $action_orderby,
		order_by  => $action_orderby,
		order     => $action_orderby,
		sortby    => $action_orderby,
		sort_by   => $action_orderby,
		sort      => $action_orderby,

		groupby   => $action_groupby,
		group_by  => $action_groupby,
		group     => $action_groupby,

		limit     => $action_limit,

		offset    => $action_offset,

		distinct  => $action_distinct,
	},
);

sub parse_labels
{
	my ($S, $lop) = @_;
	my $label = $labelmap{$S->{operation}}->{lc $lop->label};
	if (!$label && lc $lop->label eq "table") {
		$label = { kind => 'table' };
	}
	bailout $S, "label ", $lop->label, " is not understood"
		unless $label;
	my $op = $lop->sibling;
	if ($label->{kind} eq "termlist") {
		my @op;
		if (is_listop($op, "list")) {
			@op = get_all_children($op);
		} else {
			push @op, $op;
		}
		my $order = "";
		for $op (@op) {
			next if is_op($op, "pushmark");
			my $term;
			$term = parse_term($S, $op)
				unless $term = is_const($S, $op);
			if ($label->{key} eq "order_by") {
				# special case for sort order
				if ($term =~ /^asc/i) {
					next;  # skip "ascending"
				} elsif ($term =~ /^desc/i) {
					$order = "desc";
					next;
				} else {
					if ($order) {
						push @{$S->{$label->{key}}}, "$term $order";
						$order = "";
					} else {
						push @{$S->{$label->{key}}}, $term;
					}
				}
			} else {
				push @{$S->{$label->{key}}}, $term;
			}
		}
		$S->{skipnext} = 1;
	} elsif ($label->{kind} eq "fieldlist") {
		my @op;
		if (is_listop($op, "list")) {
			@op = get_all_children($op);
		} else {
			push @op, $op;
		}
		for $op (@op) {
			next if is_op($op, "pushmark");
			my ($t, $f) = get_tab_field($S, $op);
			push @{$S->{$label->{key}}},
				($S->{operation} eq "delete" || $S->{operation} eq "update") ?
				$f : "$t.$f";
		}
		$S->{skipnext} = 1;
	} elsif ($label->{kind} eq "numassign") {
		# TODO more generic values
		my ($const,$sv) = is_const($S, $op);
		if (!$sv && is_op($op, "padsv")) {
			if (find_aliased_tab($S, $op)) {
				bailout $S, "cannot use table variable after ", $lop->label;
			}
			$sv = $S->{padlist}->[1]->ARRAYelt($op->targ);
			$const = ${$sv->object_2svref};
		}
		bailout $S, "label ", $lop->label, " must be followed by an integer or integer variable"
			unless $sv && ref $sv eq "B::IV";
		$S->{$label->{key}} = $const;
		$S->{skipnext} = 1;
	} elsif ($label->{kind} eq "notice") {
		$S->{$label->{key}}++;
	} elsif ($label->{kind} eq "table") {
		bailout $S, "label ", $lop->label, " must be followed by an assignment"
			unless $op->name eq "sassign";
		my $attr = parse_simple_term($S, $op->first);
		my $varn;
		bailout $S, "label ", $lop->label, " must be followed by a lexical variable declaration"
			unless is_op($op->last, "padsv") && ($varn = padname($S, $op->last, no_fakes => 1));
		new_var($S, $varn, $attr);
		$S->{skipnext} = 1;
	} else {
		bailout $S, "internal error parsing label ", $op->label;
	}
}

sub parse_op
{
	my ($S, $op) = @_;

	if ($S->{skipnext}) {
		delete $S->{skipnext};
		return;
	}
	if (is_listop($op, "list")) {
		parse_list($S, $op);
	} elsif (is_listop($op, "lineseq")) {
		parse_list($S, $op);
	} elsif (is_binop($op, "leaveloop") &&
			 is_loop($op->first, "enterloop") &&
			 is_listop($op->last, "lineseq"))
	{
		parse_list($S, $op->last);
	} elsif (is_listop($op, "return")) {
		parse_return($S, $op);
	} elsif (is_binop($op)) {
		push @{$S->{where}}, parse_expr($S, $op);
	} elsif (is_unop($op, "not")) {
		push @{$S->{where}}, scalar parse_term($S, $op);
	} elsif (is_logop($op, "or")) {
		my $or = parse_or($S, $op);
		push @{$S->{where}}, $or if $or;
	} elsif (is_logop($op, "and")) {
		my $and = parse_and($S, $op);
		push @{$S->{where}}, $and if $and;
	} elsif (is_unop($op, "leavesub")) {
		parse_op($S, $op->first);
	} elsif (is_unop($op, "null")) {
		parse_op($S, $op->first);
	} elsif (is_unop($op, "defined")) {
		push @{$S->{where}}, scalar parse_term($S, $op);
	} elsif (is_op($op, "padsv")) {
		# XXX Skip for now, it is either a variable
		# that does not represent a table, or else
		# it is already associated with a table in $S.
	} elsif (is_op($op, "last")) {
		bailout $S, "there should be no \"last\" statements in $S->{operation}'s query sub"
			unless $S->{operation} eq "select";
		$S->{limit} = 1;
	} elsif (is_op($op, "pushmark")) {
		# skip
	} elsif (is_cop($op, "nextstate")) {
		$S->{file} = $op->file;
		$S->{line} = $op->line;
		if ($op->label) {
			parse_labels($S, $op);
		}
	} elsif (is_cop($op)) {
		# XXX any other things?
		$S->{file} = $op->file;
		$S->{line} = $op->line;
		# skip
	} elsif (is_unop($op, "entersub")) {
		push @{$S->{where}}, parse_entersub($S, $op);
	} elsif (ref($op) eq "B::PMOP" && $op->name eq "match") {
		push @{$S->{where}}, parse_regex( $S, $op, 0);
	} elsif ( $op-> name eq 'join') {
		push @{$S->{joins}}, parse_join( $S, $op);
	} else {
		print "$op\n";
		if (ref($op) eq "B::PMOP") {
			print "reg: ", $op->precomp, "\n";
		}
		print "type: ", $op->type, "\n";
		print "name: ", $op->name, "\n";
		print "desc: ", $op->desc, "\n";
		print "targ: ", $op->targ, "\n";
		bailout $S, "???";
	}
}

sub parse_sub
{
	my ($S, $sub) = @_;
	if ($DEVEL) {
		$Carp::Verbose = 1;
		require B::Concise;
		my $walker = B::Concise::compile('-terse', $sub);
		print "CODE DUMP:\n";
		$walker->();
		print "\n\n";
	}
	my $root = B::svref_2object($sub);
	$S->{padlist} = [$root->PADLIST->ARRAY];
	$root = $root->ROOT;
	parse_op($S, $root);
}

sub init
{
	my %args = @_;
	my $S = {
		gen_args   => \%args,
		file       => '??',
		line       => '??',
		subselect  => 's01',
		operation  => $args{operation},
		values     => [],
		sets       => [],
		set_values => [],
		ret_values => [],
		order_by   => [],
		group_by   => [],
		additions  => [],
		joins      => [],
		aggregates => { avg => 1, count => 1, max => 1, min => 1, sum => 1 },
		autogroup_by     => [],
		autogroup_fields => {},
	};
	$S->{alias} = $args{prefix} ? "$args{prefix}_t01" : "t01";
	$S;
}

# Borrowed from IO::All by Ingy döt Net.
my $old_warn_handler = $SIG{__WARN__}; 
$SIG{__WARN__} = sub { 
	if ($_[0] !~ /^Useless use of .+ in void context/) {
		goto &$old_warn_handler if $old_warn_handler;
		warn(@_);
	}
};

1;
