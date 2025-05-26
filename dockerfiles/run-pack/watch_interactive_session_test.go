package main

import (
	"fmt"
	"log"
	"testing"

	ps "github.com/mitchellh/go-ps"
)

type ProcessMock struct {
	pid  int
	ppid int
}

func (p *ProcessMock) Pid() int {
	return p.pid
}

func (p *ProcessMock) PPid() int {
	return p.ppid
}

func (p *ProcessMock) Executable() string {
	return "executable"
}

func TestOtherSessionRunning(t *testing.T) {
	log.Println(fmt.Sprintf("Interactive session has not started for %d seconds", 123))
	ps1 := []ps.Process{
		&ProcessMock{pid: 1, ppid: 0},
		&ProcessMock{pid: 10, ppid: 1},
	}
	p, err := otherSessionRunning(ps1)
	if err != nil {
		t.Fatalf("err: %s", err)
	}
	if p != nil {
		t.Fatalf("expected nil actual: %+x", p)
	}

	ps2 := []ps.Process{
		&ProcessMock{pid: 1, ppid: 0},
		&ProcessMock{pid: 10, ppid: 0},
	}
	p, err = otherSessionRunning(ps2)

	if err != nil {
		t.Fatalf("err: %s", err)
	}
	if p == nil || !(p.Pid() == 10 && p.PPid() == 0) {
		t.Fatalf("expected p actual: %v", p)
	}
}
