let Severity = < Off | Info | Warning | Error >

let overrideOff = \(id : Text) -> { id, severity = Severity.Off, reason = None Text }

in  { profile = "standard"
    , extra-ignores = [ "test/fixtures/**" ]
    , overrides = [ overrideOff "long-inline-string" ]
    }
