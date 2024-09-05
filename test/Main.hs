{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Data.SplayTree
import Test.Hspec
import Test.Hspec.QuickCheck

main :: IO ()
main = hspec do
  prop "roundtripping on lists" \(x :: [Int]) -> fromList x
