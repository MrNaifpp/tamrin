//
//  ActivityDetailsView.swift
//  Sirr
//
//  Created by فارس أبومالح on 15/05/1447 AH.
//

import SwiftUI

struct ActivityDetailsView: View {
    var body: some View {
        ZStack {
            Rectangle()
                .ignoresSafeArea()
                .overlay {
                    Image(.pic)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 60)
                }
            VStack(spacing: 60) {
                VStack(spacing: 24) {
                    Rectangle()
                        .frame(height: 220)
                        .overlay {
                            Image(.pic)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        }
                        .clipShape(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .padding(.horizontal, 20)
                        .shadow(color: .black.opacity(0.2), radius: 20)
                    VStack(spacing: 10) {
                        Text("التمرين الأسبوعي")
                            .font(.system(size: 28))
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                        Text("يوم الثلاثاء، الساعة 6:00 م")
                            .font(.system(size: 20))
                            .fontWeight(.medium)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                VStack(spacing: 40) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .foregroundStyle(.black)
                            .fontWeight(.semibold)
                        Text("سجل في التمرين")
                            .font(.system(size: 20))
                            .fontWeight(.semibold)
                            .foregroundStyle(.black)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.7)))
                                        VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                            .foregroundStyle(.gray)
                        Text("محمد معلا")
                            .font(.system(size: 20))
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.1)))
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                            .foregroundStyle(.gray)
                        Text("محمد معلا")
                            .font(.system(size: 20))
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.1)))
                }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
    }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.red.opacity(0.1)))
//        .padding(16)
        .ignoresSafeArea()

    }
}

#Preview {
    ActivityDetailsView()
}
