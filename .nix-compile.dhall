let Severity = < Off | Info | Warning | Error >

let overrideOff = \(id : Text) -> { id, severity = Severity.Off, reason = None Text }

in  { profile = "standard"
    , layout = "straylight"
    , extra-ignores =
      [ "test/fixtures/**"
      , "tools/adversarial_output/**"
      , "tools/fmtparity/**"
      ]
    , overrides = [ overrideOff "long-inline-string" ]
    }
