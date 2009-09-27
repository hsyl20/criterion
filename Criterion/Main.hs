-- |
-- Module      : Criterion.Main
-- Copyright   : (c) Bryan O'Sullivan 2009
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Stability   : experimental
-- Portability : GHC
--
-- Simple @main@ wrappers for benchmarking.
--
-- Example:
--
-- > {-# LANGUAGE ScopedTypeVariables #-}
-- > {-# OPTIONS_GHC -fno-full-laziness #-}
-- >
-- > import Criterion.Main
-- >
-- > fib :: Int -> Int
-- > fib 0 = 0
-- > fib 1 = 1
-- > fib n = fib (n-1) + fib (n-2)
-- >
-- > main = defaultMain [
-- >        bgroup \"fib\" [ bench \"fib 10\" (\(_::Int) -> fib 10)
-- >                       , bench \"fib 35\" (\(_::Int) -> fib 35)
-- >                       , bench \"fib 37\" (\(_::Int) -> fib 37)
-- >                       ]
-- >                    ]

module Criterion.Main
    (
      Benchmarkable(..)
    , Benchmark
    , bench
    , bgroup
    , defaultMain
    , defaultMainWith
    , defaultOptions
    , parseArgs
    ) where

import Control.Monad (MonadPlus(..))
import Criterion (runAndAnalyse)
import Criterion.Config
import Criterion.Environment (measureEnvironment)
import Criterion.IO (note, printError)
import Criterion.MultiMap (singleton)
import Criterion.Types (Benchmarkable(..), Benchmark, bench, benchNames, bgroup)
import Data.List (isPrefixOf, sort)
import Data.Monoid (Monoid(..), Last(..))
import System.Console.GetOpt
import System.Environment (getArgs, getProgName)
import System.Exit (ExitCode(..), exitWith)
import Text.ParserCombinators.Parsec

-- | Parse a plot output.
parsePlot :: Parser PlotOutput
parsePlot = try (dim "window" Window 800 600)
    `mplus` try (dim "win" Window 800 600)
    `mplus` try (dim "pdf" PDF 432 324)
    `mplus` try (dim "png" PNG 800 600)
    `mplus` try (dim "svg" SVG 432 324)
    `mplus` (string "csv" >> return CSV)
  where dim s c dx dy = do
          string s
          try (uncurry c `fmap` dimensions) `mplus`
              (eof >> return (c dx dy))
        dimensions = do
            char ':'
            a <- many1 digit
            char 'x'
            b <- many1 digit
            case (reads a, reads b) of
              ([(x,[])],[(y,[])]) -> return (x, y)
              _                   -> mzero
           <?> "dimensions"

-- | Parse a plot type.
plot :: Plot -> String -> IO Config
plot p s = case parse parsePlot "" s of
             Left _err -> parseError "unknown plot type\n"
             Right t   -> return mempty { cfgPlot = singleton p t }

-- | Parse a confidence interval.
ci :: String -> IO Config
ci s = case reads s' of
         [(d,"%")] -> check (d/100)
         [(d,"")]  -> check d
         _         -> parseError "invalid confidence interval provided"
  where s' = case s of
               ('.':_) -> '0':s
               _       -> s
        check d | d <= 0 = parseError "confidence interval is negative"
                | d >= 1 = parseError "confidence interval is greater than 1"
                | otherwise = return mempty { cfgConfInterval = ljust d }

-- | Parse a positive number.
pos :: (Num a, Ord a, Read a) =>
       String -> (Last a -> Config) -> String -> IO Config
pos q f s =
    case reads s of
      [(n,"")] | n > 0     -> return . f $ ljust n
               | otherwise -> parseError $ q ++ " must be positive"
      _                    -> parseError $ "invalid " ++ q ++ " provided"

noArg :: Config -> ArgDescr (IO Config)
noArg = NoArg . return

defaultOptions :: [OptDescr (IO Config)]
defaultOptions = [
   Option ['h','?'] ["help"] (noArg mempty { cfgPrintExit = Help })
          "print help, then exit"
 , Option ['G'] ["no-gc"] (noArg mempty { cfgPerformGC = ljust False })
          "do not collect garbage between iterations"
 , Option ['g'] ["gc"] (noArg mempty { cfgPerformGC = ljust True })
          "collect garbage between iterations"
 , Option ['I'] ["ci"] (ReqArg ci "CI")
          "bootstrap confidence interval"
 , Option ['l'] ["--list"] (noArg mempty { cfgPrintExit = List })
          "print a list of benchmarks"
 , Option ['k'] ["plot-kde"] (ReqArg (plot KernelDensity) "TYPE")
          "plot kernel density estimate of probabilities"
 , Option ['q'] ["quiet"] (noArg mempty { cfgVerbosity = ljust Quiet })
          "print less output"
 , Option [] ["resamples"]
          (ReqArg (pos "resample count"$ \n -> mempty { cfgResamples = n }) "N")
          "number of bootstrap resamples to perform"
 , Option ['s'] ["samples"]
          (ReqArg (pos "sample count" $ \n -> mempty { cfgSamples = n }) "N")
          "number of samples to collect"
 , Option ['t'] ["plot-timing"] (ReqArg (plot Timing) "TYPE")
          "plot timings"
 , Option ['V'] ["version"] (noArg mempty { cfgPrintExit = Version })
          "display version, then exit"
 , Option ['v'] ["verbose"] (noArg mempty { cfgVerbosity = ljust Verbose })
          "print more output"
 ]

printBanner :: Config -> IO ()
printBanner cfg =
    case cfgBanner cfg of
      Last (Just b) -> note cfg "%s\n" b
      _             -> note cfg "Hey, nobody told me what version I am!\n"

printUsage :: [OptDescr (IO Config)] -> ExitCode -> IO a
printUsage options exitCode = do
  p <- getProgName
  putStr (usageInfo ("Usage: " ++ p ++ " [OPTIONS]") options)
  mapM_ putStrLn [
       ""
    , "Plot types:"
    , "  window or win   display a window immediately"
    , "  csv             save a CSV file"
    , "  pdf             save a PDF file"
    , "  png             save a PNG file"
    , "  svg             save an SVG file"
    , ""
    , "You can specify plot dimensions via a suffix, e.g. \"window:640x480\""
    , "Units are pixels for png and window, 72dpi points for pdf and svg"
    ]
  exitWith exitCode

-- | Parse command line options.
parseArgs :: Config -> [OptDescr (IO Config)] -> [String]
          -> IO (Config, [String])
parseArgs defCfg options args =
  case getOpt Permute options args of
    (_, _, (err:_)) -> parseError err
    (opts, rest, _) -> do
      cfg <- (mappend defCfg . mconcat) `fmap` sequence opts
      case cfgPrintExit cfg of
        Help ->    printBanner cfg >> printUsage options ExitSuccess
        Version -> printBanner cfg >> exitWith ExitSuccess
        _ ->       return (cfg, rest)

-- | An entry point that can be used as a @main@ function.
defaultMain :: [Benchmark] -> IO ()
defaultMain = defaultMainWith defaultConfig

-- | An entry point that can be used as a @main@ function, with
-- configurable defaults.
defaultMainWith :: Config -> [Benchmark] -> IO ()
defaultMainWith defCfg bs = do
  (cfg, args) <- parseArgs defCfg defaultOptions =<< getArgs
  if cfgPrintExit cfg == List
    then do
      note cfg "Benchmarks:\n"
      mapM_ (note cfg "  %s\n") (sort $ concatMap benchNames bs)
    else do
      env <- measureEnvironment cfg
      let shouldRun b = null args || any (`isPrefixOf` b) args
      mapM_ (runAndAnalyse shouldRun cfg env) bs

-- | Display an error message from a command line parsing failure, and
-- exit.
parseError :: String -> IO a
parseError msg = do
  printError "Error: %s" msg
  printError "Run \"%s --help\" for usage information\n" =<< getProgName
  exitWith (ExitFailure 64)
