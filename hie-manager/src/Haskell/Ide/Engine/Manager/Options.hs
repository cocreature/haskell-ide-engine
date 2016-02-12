{-# LANGUAGE OverloadedStrings #-}
module Haskell.Ide.Engine.Manager.Options
  (ManagerOpts(..)
  ,managerOpts
  ) where

import Options.Applicative

data ManagerOpts = ManagerOpts {port :: Int}

managerOpts :: Parser ManagerOpts
managerOpts =
  ManagerOpts <$>
  option auto
         (long "port" <> metavar "PORT" <> help "port used for communication" <>
          value 8889)
