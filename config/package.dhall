-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                    // nix-compile // config
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--
--     "Wintermute could build a kind of personality into a shell."
--
--                                                                — Neuromancer
--
-- Usage:
--
--   let NixCompile = https://raw.githubusercontent.com/.../config/package.dhall
--
--   in NixCompile.Config::{
--     , profile = "standard"
--     , overrides = [
--         NixCompile.override "rec-anywhere" NixCompile.Severity.Off
--       ]
--     }
--

let Types = ./types.dhall

let Rules = ./rules.dhall

let Profiles = ./profiles.dhall

-- Helper to create rule overrides
let override =
      λ(id : Text) →
      λ(severity : Types.Severity) →
        { id, severity, reason = None Text } : Types.RuleOverride

let override-with-reason =
      λ(id : Text) →
      λ(severity : Types.Severity) →
      λ(reason : Text) →
        { id, severity, reason = Some reason } : Types.RuleOverride

-- Default config
let default-config
    : Types.Config
    = { profile = "standard"
      , extra-ignores = [] : List Text
      , overrides = [] : List Types.RuleOverride
      }

in  { -- Types
      Severity = Types.Severity
    , Language = Types.Language
    , RuleOverride = Types.RuleOverride
    , Profile = Types.Profile
    , Config = Types.Config
    , -- Rules
      rule-ids = Rules.rule-ids
    , all-rules = Rules.all-rules
    , -- Profiles
      profiles = Profiles
    , -- Helpers
      override
    , override-with-reason
    , default-config
    }
