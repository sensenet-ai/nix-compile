-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                     // types
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--     "The matrix has its roots in primitive arcade games."
--
--                                                                — Neuromancer
--

let Severity = < Error | Warning | Info | Off >

let Language = < Nix | Cpp | Bash | Any >

let RuleOverride =
      { id : Text
      , severity : Severity
      , reason : Optional Text
      }

let Profile =
      { name : Text
      , description : Text
      , parent : Optional Text
      , rules : List RuleOverride
      , ignores : List Text
      , files : Optional (List Text)
      }

let Config =
      { profile : Text
      , extra-ignores : List Text
      , overrides : List RuleOverride
      }

in  { Severity, Language, RuleOverride, Profile, Config }
