# ecount

Simple Erlang counters, dynamically named.

Build with rebar3:

    rebar3 compile

OTP versions support: 21.2 and above.

## License
License is available in the LICENSE file in the root directory of this source tree.

## Usage

This application is supposed to be used as a part of another project that requires counters/gauges support.
In rebar.config file, add depdency to ```{deps, [ecount]}```.

To bump the counter, use

    ecount:count(CounterName).
    
To get a single counter, use

    ecount:get(CounterName).
    
To fetch full map of counters with names and values, use

    ecount:all().
    
## Planned features

This application is merely an example, missing many features needed for proper integration. There are plans to add:
 * name normalisation (e.g. 'counter.name', <<"counter.name">> and "counter.name" should be one counter)
 * composite names and aggregation ({aggregate, counter})
 * gauges 
 * integration with external systems