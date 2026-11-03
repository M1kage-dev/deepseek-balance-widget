import Foundation

/// Одно наблюдение баланса из GET https://api.deepseek.com/user/balance
struct BalanceSample: Codable {
    var t: Int          // unix seconds
    var cny: Double?    // total_balance в CNY, nil если валюты нет в ответе
    var usd: Double?
}

/// Что виджет знает про один календарный день.
struct DaySpend: Equatable {
    var spent: Double = 0                 // потрачено за день
    var samples: Int = 0                  // сколько наблюдений попало в день
    var coversFromMidnight: Bool = false  // первое наблюдение близко к 00:00
    var firstT: Int? = nil
    var lastT: Int? = nil
}

enum SpendLogic {
    /// Траты за `day` = сумма падений баланса между соседними наблюдениями внутри дня.
    /// Рост баланса (пополнение) не отрицательная трата — он просто сдвигает baseline:
    /// расходом считается только то, что убыло (unclebob: illegal state невозможно записать —
    /// отрицательной траты в типе не появляется).
    static func daySpend(_ samples: [BalanceSample],
                         day: Date,
                         value: (BalanceSample) -> Double?,
                         cal: Calendar,
                         midnightSlack: TimeInterval = 1800) -> DaySpend {
        let inDay = inside(samples, day: day, value: value, cal: cal)
        var spent = 0.0
        var previous: Double?
        for sample in inDay {
            guard let current = value(sample) else { continue }
            if let p = previous, p > current { spent += p - current }
            previous = current
        }
        let startOfDay = cal.startOfDay(for: day)
        let first = inDay.first.map { Date(timeIntervalSince1970: TimeInterval($0.t)) }
        let covers = first.map { $0 <= startOfDay.addingTimeInterval(midnightSlack) } ?? false
        return DaySpend(spent: round2(spent),
                        samples: inDay.count,
                        coversFromMidnight: covers,
                        firstT: inDay.first?.t,
                        lastT: inDay.last?.t)
    }

    /// Точки для спарклайна: (время, баланс) за последние `window` секунд.
    /// Если наблюдений больше `maxPoints` — прореживаются по времени (сохраняются
    /// первая и последняя точки). Хвост дотягивается до `now`: между замерами
    /// баланс неизвестен, но он не менялся — рисуем последнее известное значение.
    static func spark(_ samples: [BalanceSample],
                      now: Date,
                      window: TimeInterval,
                      maxPoints: Int,
                      value: (BalanceSample) -> Double?) -> [(t: Int, v: Double)] {
        guard maxPoints > 1, window > 0 else { return [] }
        let end = Int(now.timeIntervalSince1970)
        let start = end - Int(window)
        var points: [(t: Int, v: Double)] = samples
            .filter { $0.t >= start && $0.t <= end }
            .compactMap { sample in value(sample).map { (sample.t, $0) } }
            .sorted { $0.t < $1.t }
        guard let last = points.last else { return [] }

        if points.count > maxPoints {
            let step = window / Double(maxPoints - 1)
            var kept: [(t: Int, v: Double)] = [points[0]]
            for point in points.dropFirst() where Double(point.t - kept[kept.count - 1].t) >= step {
                kept.append(point)
            }
            if kept.last!.t != last.t { kept.append(last) }
            points = kept
        }
        if last.t < end { points.append((end, last.v)) }
        return points
    }

    /// Наблюдения этого дня с ненулевой выбранной валютой, по возрастанию времени.
    private static func inside(_ samples: [BalanceSample],
                               day: Date,
                               value: (BalanceSample) -> Double?,
                               cal: Calendar) -> [BalanceSample] {
        return samples
            .filter { sample in
                value(sample) != nil &&
                cal.isDate(Date(timeIntervalSince1970: TimeInterval(sample.t)), inSameDayAs: day)
            }
            .sorted { $0.t < $1.t }
    }

    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}
