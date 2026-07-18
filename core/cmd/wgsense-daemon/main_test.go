package main

import (
	"reflect"
	"testing"
)

func TestSplitCommaSeparated(t *testing.T) {
	got := splitCommaSeparated(" 10.10.1.,192.168.1. , , 172.16. ")
	want := []string{"10.10.1.", "192.168.1.", "172.16."}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("splitCommaSeparated() = %#v, want %#v", got, want)
	}
}

func TestSplitCommaSeparatedEmpty(t *testing.T) {
	if got := splitCommaSeparated(" , "); len(got) != 0 {
		t.Fatalf("splitCommaSeparated() = %#v, want empty", got)
	}
}
