# Word Difficulty Calculation System

This document explains how word difficulty is automatically calculated in the Hangman game database.

## Overview

Word difficulty is calculated on a **0-100 scale** (stored as integer) but internally computed as 0-1 for precision. The calculation considers three main factors:

1. **Unique Letter Ratio** (40% weight)
2. **Letter Rarity** (35% weight)  
3. **Word Length** (25% weight)

## Calculation Formula

```
difficulty = (unique_ratio × 0.40) + (letter_rarity × 0.35) + (length_score × 0.25)
```

### 1. Unique Letter Ratio (40%)

Measures how many letters in the word are unique vs repeated.

**Example:**
- `LEVEL` = 4 unique letters / 5 total = 0.80 (harder)
- `AAAAAA` = 1 unique letter / 6 total = 0.17 (easier)

**Why it matters:** Words with many repeated letters are easier because you get more reveals per guess.

### 2. Letter Rarity (35%)

Based on language-specific letter frequency tables. Common letters = lower difficulty, rare letters = higher difficulty.

**English letter frequency (most to least common):**
```
E(1.0) T(0.91) A(0.82) O(0.75) I(0.70) ... X(0.02) Q(0.01) Z(0.01)
```

**Spanish letter frequency (most to least common):**
```
E(1.0) A(0.95) O(0.87) S(0.80) R(0.75) ... X(0.02) W(0.00) K(0.00)
```

**Example:**
- `QUIZ` (English) = contains Q, Z (rare) = higher difficulty
- `ESTE` (Spanish) = contains E, S, T, E (common) = lower difficulty

**Why it matters:** Players tend to guess common letters first (E, A, T, O). Words with rare letters are harder to guess.

### 3. Word Length (25%)

Longer words are generally harder, but with diminishing returns after 10 letters.

**Scoring:**
- 3-5 letters = 0.2-0.4 (easier)
- 6-8 letters = 0.4-0.6 (medium)
- 9+ letters = 0.6-1.0 (harder)

**Formula:** `(length - 3) / 12` (capped at 0-1)

**Why it matters:** Longer words require more correct guesses and provide more chances to fail.

## Database Components

### 1. Letter Frequency Table

```sql
CREATE TABLE hangman_letter_frequencies (
    letter CHAR(1) NOT NULL,
    locale TEXT NOT NULL,
    frequency NUMERIC(3,2) NOT NULL, -- 0.00 to 1.00
    PRIMARY KEY (letter, locale)
);
```

Contains normalized frequency data for each letter in English and Spanish.

### 2. Calculation Function

```sql
hangman_calculate_word_difficulty(word_text TEXT, word_locale TEXT DEFAULT 'en')
RETURNS NUMERIC -- Returns 0-1
```

Pure function that calculates difficulty for any word.

**Usage:**
```sql
-- Get difficulty for a single word
SELECT hangman_calculate_word_difficulty('DEVELOPER', 'en');
-- Returns: 0.58

SELECT hangman_calculate_word_difficulty('MURCIÉLAGO', 'es');
-- Returns: 0.71
```

### 3. Update Procedures

#### Update All Words
```sql
SELECT hangman_update_all_word_difficulties();
-- Returns number of updated rows
```

#### Update by Locale
```sql
SELECT hangman_update_word_difficulties_by_locale('en');
-- Returns number of updated rows for English
```

### 4. Automatic Trigger

Words automatically recalculate difficulty when inserted or updated:

```sql
CREATE TRIGGER calculate_difficulty_on_change
    BEFORE INSERT OR UPDATE ON public.hangman_words
    FOR EACH ROW
    EXECUTE FUNCTION hangman_trigger_calculate_word_difficulty();
```

**Behavior:**
- ✅ Automatically runs on INSERT
- ✅ Automatically runs on UPDATE (if word or locale changed)
- ✅ Prevents manual override issues

## Usage Examples

### Example 1: Manual Calculation

```sql
-- Calculate difficulty for specific words
SELECT 
    word,
    locale,
    hangman_calculate_word_difficulty(word, locale) as difficulty_0_1,
    ROUND(hangman_calculate_word_difficulty(word, locale) * 100) as difficulty_0_100
FROM public.hangman_words
WHERE word IN ('CAT', 'PROGRAMMING', 'QUIZ')
    AND locale = 'en';
```

**Expected Results:**
| word | locale | difficulty_0_1 | difficulty_0_100 |
|------|--------|----------------|------------------|
| CAT | en | 0.23 | 23 |
| PROGRAMMING | en | 0.67 | 67 |
| QUIZ | en | 0.72 | 72 |

### Example 2: Update All Words

```sql
-- Recalculate all word difficulties
SELECT hangman_update_all_word_difficulties();
-- Returns: 523 (number of words updated)
```

### Example 3: Update Only Spanish Words

```sql
SELECT hangman_update_word_difficulties_by_locale('es');
-- Returns: 267 (number of Spanish words updated)
```

### Example 4: Verify Difficulty Distribution

```sql
-- See difficulty distribution
SELECT 
    CASE 
        WHEN difficulty_value BETWEEN 0 AND 33 THEN 'Easy'
        WHEN difficulty_value BETWEEN 34 AND 66 THEN 'Medium'
        ELSE 'Hard'
    END as category,
    locale,
    COUNT(*) as word_count,
    ROUND(AVG(difficulty_value)) as avg_difficulty
FROM public.hangman_words
GROUP BY category, locale
ORDER BY locale, avg_difficulty;
```

## Difficulty Categories

The app uses these categories for game settings:

| Category | Difficulty Range | Description |
|----------|------------------|-------------|
| **Easy** | 0-33 | Short words, common letters, many repeats |
| **Medium** | 34-66 | Moderate length, mixed letter frequency |
| **Hard** | 67-100 | Long words, rare letters, few repeats |

## Customization

To adjust the difficulty algorithm, modify these weights in the migration file:

```sql
final_difficulty := (
    (unique_ratio * 0.40) +        -- Adjust: Unique letter weight
    (avg_letter_frequency * 0.35) + -- Adjust: Letter rarity weight
    (length_score * 0.25)           -- Adjust: Length weight
);
```

To update letter frequencies:

```sql
UPDATE hangman_letter_frequencies
SET frequency = 0.95
WHERE letter = 'E' AND locale = 'en';

-- Then recalculate all words
SELECT hangman_update_all_word_difficulties();
```

## Implementation Notes

1. **Automatic Updates**: The trigger ensures all new words get difficulty values automatically
2. **Performance**: The `hangman_calculate_word_difficulty` function is marked as `IMMUTABLE` for caching
3. **Validation**: Difficulty values are constrained to 0-100 range
4. **Locale Support**: Different letter frequencies for English and Spanish
5. **Extensibility**: Easy to add new locales by inserting letter frequencies

## Testing

Run these queries to verify the system works:

```sql
-- Test 1: Insert new word (should auto-calculate)
INSERT INTO public.hangman_words (word, locale) 
VALUES ('TESTING', 'en')
RETURNING word, difficulty_value;

-- Test 2: Update existing word (should recalculate)
UPDATE public.hangman_words 
SET word = 'TESTED'
WHERE word = 'TESTING'
RETURNING word, difficulty_value;

-- Test 3: Verify letter frequencies exist
SELECT locale, COUNT(*) as letter_count
FROM hangman_letter_frequencies
GROUP BY locale;

-- Test 4: Check difficulty distribution
SELECT 
    MIN(difficulty_value) as min_diff,
    MAX(difficulty_value) as max_diff,
    ROUND(AVG(difficulty_value)) as avg_diff
FROM public.hangman_words;
```

## Maintenance

To keep the system accurate:

1. **Periodically review** letter frequencies for accuracy
2. **Test** difficulty distribution with actual gameplay data
3. **Adjust weights** based on player feedback
4. **Run update procedure** after any formula changes:
   ```sql
   SELECT hangman_update_all_word_difficulties();
   ```

