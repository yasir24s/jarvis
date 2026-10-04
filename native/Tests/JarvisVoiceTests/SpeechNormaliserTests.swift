import Foundation
import Testing
@testable import JarvisVoice

/// V7: what every voice is given, as a table of written → spoken (DEV-V7-01; Python had no
/// equivalent). The numbers are made up: Ofcom's drama ranges (07700 900xxx, 020 7946 0xxx,
/// 0161 496 0xxx) and example.com.
@Suite("V7 spoken forms")
struct SpeechNormaliserTests {
    static let table: [(String, String)] = [
        // Phone numbers: digit by digit, 0 as "oh", a pause between the groups.
        ("Her number is 07700 900123 and her email is name@example.co.uk.",
         "Her number is oh seven seven oh oh, nine oh oh one two three and her email is name at example dot co dot uk."),
        ("Call 07700900123.", "Call oh seven seven oh oh, nine oh oh one two three."),
        ("Call +44 7700 900123 now.", "Call plus four four, seven seven oh oh, nine oh oh one two three now."),
        ("Call +447700900123.", "Call plus four four, seven seven oh oh, nine oh oh one two three."),
        ("The office is +44 (0)20 7946 0018.", "The office is plus four four, two oh, seven nine four six, oh oh one eight."),
        ("The office is 020 7946 0018.", "The office is oh two oh, seven nine four six, oh oh one eight."),
        ("Ring 02079460018.", "Ring oh two oh, seven nine four six, oh oh one eight."),
        ("Ring 0161 496 0000 or 0161-496-0001.",
         "Ring oh one six one, four nine six, oh oh oh oh or oh one six one, four nine six, oh oh oh one."),
        ("Ring 01614960000.", "Ring oh one six one, four nine six, oh oh oh oh."),
        ("Freephone 0800 123 4567.", "Freephone oh eight oh oh, one two three, four five six seven."),
        // Email and web addresses.
        ("Write to first.last+news@example.com", "Write to first dot last plus news at example dot com"),
        ("Mail team42@example.org.", "Mail team four two at example dot org."),
        ("See https://www.example.com/news?id=4 for more.", "See example dot com for more."),
        ("Go to www.example.co.uk.", "Go to example dot co dot uk."),
        ("It's on example.com/help, sir.", "It's on example dot com, sir."),
        ("I found it on example.com/help yesterday.", "I found it on example dot com yesterday."),
        // A link being given is read in full.
        ("The link is https://www.example.com/news/uk-politics?id=4.",
         "The link is example dot com slash news slash uk politics and some parameters."),
        ("https://example.org/docs/v2/setup.html", "example dot org slash docs slash v two slash setup dot html"),
        ("Here you are, sir: https://example.com/a#top", "Here you are, sir: example dot com slash a"),
        ("Address is: www.example.co.uk/contact-us", "Address is: example dot co dot uk slash contact us"),
        ("The URL is example.com/help_centre, sir, if you need it.",
         "The URL is example dot com slash help centre, sir, if you need it."),
        // Times, British, 12-hour.
        ("It's 23:52.", "It's eleven fifty-two p m."),
        ("It's 3:45 PM.", "It's three forty-five p m."),
        ("The 3:45pm train.", "The three forty-five p m train."),
        ("At 7:30 a.m. sharp.", "At seven thirty a m. sharp."),
        ("It's 9:05 now.", "It's nine oh five now."),
        ("Meet at 15:00.", "Meet at three p m."),
        ("Up at 09:05.", "Up at nine oh five a m."),
        ("Back by 00:15.", "Back by twelve fifteen a m."),
        ("Until 00:00.", "Until midnight."),
        ("At 3:00.", "At three o'clock."),
        ("At 12:30.", "At twelve thirty."),
        // Money.
        ("That costs £20.", "That costs twenty pounds."),
        ("Only £1 left.", "Only one pound left."),
        ("It was $3.99, or €2.50.", "It was three dollars ninety-nine, or two euros fifty."),
        ("Just £0.50.", "Just fifty pence."),
        ("A bill of £1,250.40.", "A bill of one thousand two hundred and fifty pounds forty."),
        ("About £1.5 each.", "About one point five pounds each."),
        // Percentages, degrees.
        ("Your battery is at 64%.", "Your battery is at sixty-four percent."),
        ("Up 12 % today, 2.5% this year.", "Up twelve percent today, two point five percent this year."),
        ("A high of 14°C, a low of -3°C.", "A high of fourteen degrees Celsius, a low of minus three degrees Celsius."),
        ("It's 70°F.", "It's seventy degrees Fahrenheit."),
        // Ordinals and dates.
        ("On the 1st, the 22nd and the 103rd.", "On the first, the twenty-second and the one hundred and third."),
        ("The 12th and the 40th.", "The twelfth and the fortieth."),
        ("Due 3 March 2026.", "Due the third of March twenty twenty-six."),
        ("Due March 3rd, 2026.", "Due March the third, twenty twenty-six."),
        ("Since May 1990.", "Since May nineteen ninety."),
        // Years in a date, numbers elsewhere.
        ("In 2026, at 0.", "In twenty twenty-six, at zero."),
        ("Built in 1905, rebuilt in 2005 and sold in 1900.",
         "Built in nineteen oh five, rebuilt in two thousand and five and sold in nineteen hundred."),
        ("Back in 2010.", "Back in twenty ten."),
        ("There are 2026 of them.", "There are two thousand and twenty-six of them."),
        // Ordinary numbers stay natural.
        ("That's 320 miles.", "That's three hundred and twenty miles."),
        ("1,500 people came.", "one thousand five hundred people came."),
        ("1,520 or 2,005 or 1,000,050.", "one thousand five hundred and twenty or two thousand and five or one million and fifty."),
        ("Pi is 3.14.", "Pi is three point one four."),
        ("Lists: 1, 2, 3.", "Lists: one, two, three."),
        ("A 12-15 minute walk.", "A twelve-fifteen minute walk."),
        ("Agent 007.", "Agent oh oh seven."),
        ("Your reference is 48213907.", "Your reference is four eight two one three nine oh seven."),
        // Left alone.
        ("An MP3 in 4K.", "An MP3 in 4K."),
        ("No digits here.", "No digits here."),
        ("e.g. this, i.e. that.", "e.g. this, i.e. that."),
        ("", ""),
    ]

    @Test(arguments: SpeechNormaliserTests.table)
    func speaksIt(_ written: String, _ spoken: String) {
        #expect(SpeechNormaliser.spoken(written) == spoken)
    }

    @Test func otherScriptsDigitsAreLeftAlone() {
        #expect(SpeechNormaliser.spoken("Arabic ٦٤ stays") == "Arabic ٦٤ stays")
    }

    /// A number with a leading 0 that is too short or too long for a phone is not read as one.
    @Test func notEveryLeadingZeroIsAPhone() {
        #expect(SpeechNormaliser.spoken("Code 0123 4567.") == "Code oh one two three four thousand five hundred and sixty-seven.")
        #expect(SpeechNormaliser.spoken("Ring 0161 496 00001 9.") == "Ring oh one six one four hundred and ninety-six oh oh oh oh one nine.")
    }

    @Test(arguments: [(0, "zero"), (7, "seven"), (13, "thirteen"), (40, "forty"), (99, "ninety-nine"),
                      (100, "one hundred"), (101, "one hundred and one"), (320, "three hundred and twenty"),
                      (1_000, "one thousand"), (1_001, "one thousand and one"), (21_000, "twenty-one thousand"),
                      (999_999, "nine hundred and ninety-nine thousand nine hundred and ninety-nine"),
                      (2_000_000, "two million")])
    func cardinals(_ n: Int, _ words: String) {
        #expect(SpeechNormaliser.cardinal(n) == words)
    }
}
