.PHONY: all deps clean release

all: compile

compile: deps
	./rebar -j8 compile

deps:
	./rebar -j8 get-deps

clean:
	./rebar -j8 clean

relclean:
	rm -rf rel/apns

generate: compile
	cd rel && .././rebar -j8 generate

run: generate
	./rel/apns/bin/apns start

console: generate
	./rel/apns/bin/apns console

foreground: generate
	./rel/apns/bin/apns foreground

erl: compile
	erl -pa ebin/ -pa deps/*/ebin/ -s apns
