package utils

import "base:intrinsics"

// interval in the most mathematical sense
Interval :: struct($T: typeid) where intrinsics.type_is_ordered(T) {
	lower:       T,
	upper:       T,
	exclusivity: Interval_Exclusivity,
}

Interval_Exclusivity :: enum {
	Open,
	Closed,
}

interval :: proc(lower, upper: $T, exclusivity := Interval_Exclusivity.Closed) -> Interval(T) {
	return Interval(T){lower, upper, exclusivity}
}

interval_lower_bound :: proc(interval: Interval($T)) -> (T, bool) #optional_ok {
	if interval.exclusivity == .Open do return {}, false
	return interval.lower, true
}

interval_upper_bound :: proc(interval: Interval($T)) -> (T, bool) #optional_ok {
	if interval.exclusivity == .Open do return {}, false
	return interval.upper, true
}

interval_contains :: proc(interval: Interval($T), value: T) -> bool {
	if interval.exclusivity == .Open do return interval.lower < value && value < interval.upper

	return interval.lower <= value && value <= interval.upper
}

interval_size :: proc(interval: Interval($T)) -> (T, bool) #optional_ok {
	if interval.exclusivity == .Open do return {}, false

	return interval.upper - interval.lower, true
}

