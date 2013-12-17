// Generated by IcedCoffeeScript 1.6.3-i
(function() {
  var SignatureEngine, gpg, iced, __iced_k, __iced_k_noop;

  iced = require('iced-coffee-script/lib/coffee-script/iced').runtime;
  __iced_k = __iced_k_noop = function() {};

  gpg = require('./gpg').gpg;

  exports.SignatureEngine = SignatureEngine = (function() {
    function SignatureEngine(_arg) {
      this.km = _arg.km;
    }

    SignatureEngine.prototype.get_km = function() {
      return this.km;
    };

    SignatureEngine.prototype.box = function(msg, cb) {
      var arg, err, out, ___iced_passed_deferral, __iced_deferrals, __iced_k;
      __iced_k = __iced_k_noop;
      ___iced_passed_deferral = iced.findDeferral(arguments);
      arg = {
        stdin: new Buffer(msg, 'utf8'),
        args: ["-u", this.km.get_pgp_key_id(), "--sign"]
      };
      (function(_this) {
        return (function(__iced_k) {
          __iced_deferrals = new iced.Deferrals(__iced_k, {
            parent: ___iced_passed_deferral,
            filename: "/Users/max/src/keybase-node-client/src/hilev.iced",
            funcname: "SignatureEngine.box"
          });
          gpg(arg, __iced_deferrals.defer({
            assign_fn: (function() {
              return function() {
                err = arguments[0];
                return out = arguments[1];
              };
            })(),
            lineno: 21
          }));
          __iced_deferrals._fulfill();
        });
      })(this)((function(_this) {
        return function() {
          return cb(err, out);
        };
      })(this));
    };

    return SignatureEngine;

  })();

}).call(this);